defmodule Attestation do
    _ = """
    attestation {
        entry_hash: <>,
        mutations_hash: <>,
        signer: <>,
        signature: <entry_hash,mutations_hash>,
    }
    """

    def pack_for_db(attestation_unpacked) when is_binary(attestation_unpacked) do attestation_unpacked end
    def pack_for_db(attestation_unpacked) do
      attestation_unpacked
      |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
      |> RDB.vecpak_encode()
    end

    def pack_for_net(attestation_unpacked) do
      attestation_unpacked
      |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
      |> :erlang.term_to_binary([:deterministic])
    end

    def sign(sk, entry_hash, mutations_hash) do
        pk = BlsEx.get_public_key!(sk)
        signature = BlsEx.sign!(sk, <<entry_hash::binary, mutations_hash::binary>>, BLS12AggSig.dst_att())
        %{
            entry_hash: entry_hash,
            mutations_hash: mutations_hash,
            signer: pk,
            signature: signature,
        }
    end

    def unpack_and_validate_from_net(a) do
        try do

        a = if is_map(a) do a else
          attestation_size = Application.fetch_env!(:ama, :attestation_size)
          if byte_size(a) >= attestation_size, do: throw(%{error: :too_large})

          a_unpacked = :erlang.binary_to_term(a, [:safe])
          |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
          if a != :erlang.term_to_binary(a_unpacked, [:deterministic]), do: throw %{error: :not_deterministicly_encoded}

          a_unpacked
        end

        if !is_binary(a.entry_hash), do: throw(%{error: :entry_hash_not_binary})
        if byte_size(a.entry_hash) != 32, do: throw(%{error: :entry_hash_not_256_bits})
        if !is_binary(a.mutations_hash), do: throw(%{error: :mutations_hash_not_binary})
        if byte_size(a.mutations_hash) != 32, do: throw(%{error: :mutations_hash_not_256_bits})
        if !is_binary(a.signer), do: throw(%{error: :signer_not_binary})
        if byte_size(a.signer) != 48, do: throw(%{error: :signer_not_48_bytes})

        bin = <<a.entry_hash::binary, a.mutations_hash::binary>>
        if !BlsEx.verify?(a.signer, a.signature, bin, BLS12AggSig.dst_att()), do: throw(%{error: :invalid_signature})

        %{error: :ok, attestation: a}
        catch
            :throw,r -> r
            e,r -> IO.inspect {Attestation, :validate, e, r}; %{error: :unknown}
        end
    end

    def validate_vs_chain(a) do
        entry = DB.Entry.by_hash(a.entry_hash)
        chain_height = DB.Chain.height()
        if !!entry and entry.header_unpacked.height <= DB.Chain.height() do
            trainers = DB.Chain.validators_for_height(Entry.height(entry))
            if !!trainers and a.signer in trainers do
                true
            end
        end
    end
end

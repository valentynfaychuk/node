defmodule Attestation do
    @doc """
    attestation {
        entry_hash: <>, 
        mutations_hash: <>,
        signer: <>,
        signature: <entry_hash,mutations_hash>,
    }
    """

    def unpack(attestation_packed) do
        :erlang.binary_to_term(attestation_packed, [:safe])
        |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
    end

    def pack(attestation_unpacked) when is_binary(attestation_unpacked) do attestation_unpacked end
    def pack(attestation_unpacked) do
        attestation_unpacked
        |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
        |> :erlang.term_to_binary([:deterministic])
    end

    def sign(entry_hash, mutations_hash) do
        pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
        sk_raw = Application.fetch_env!(:ama, :trainer_sk_raw)
        signature = BlsEx.sign!(sk_raw, <<entry_hash::binary, mutations_hash::binary>>)
        %{
            entry_hash: entry_hash,
            mutations_hash: mutations_hash,
            signer: pk_raw,
            signature: signature,
        }
    end

    def unpack_and_validate(attestation_packed) do
        try do
        attestation_size = Application.fetch_env!(:ama, :attestation_size)
        if byte_size(attestation_packed) >= attestation_size, do: throw(%{error: :too_large})
        a = :erlang.binary_to_term(attestation_packed, [:safe])
        |> Map.take([:entry_hash, :mutations_hash, :signer, :signature])
        if attestation_packed != :erlang.term_to_binary(a, [:deterministic]), do: throw %{error: :not_deterministicly_encoded}
        
        res = validate(a)
        cond do 
            res.error != :ok -> throw res
            true -> %{error: :ok, attestation: a}
        end
        catch
            :throw,r -> r
            e,r -> IO.inspect {Attestation, :unpack_and_validate, e, r, __STACKTRACE__}; %{error: :unknown}
        end
    end

    def validate(a) do
        try do
        if !is_binary(a.entry_hash), do: throw(%{error: :entry_hash_not_binary})
        if byte_size(a.entry_hash) != 32, do: throw(%{error: :entry_hash_not_256_bits})
        if !is_binary(a.mutations_hash), do: throw(%{error: :mutations_hash_not_binary})
        if byte_size(a.mutations_hash) != 32, do: throw(%{error: :mutations_hash_not_256_bits})
        if !is_binary(a.signer), do: throw(%{error: :signer_not_binary})
        if byte_size(a.signer) != 48, do: throw(%{error: :signer_not_48_bytes})

        bin = <<a.entry_hash::binary, a.mutations_hash::binary>>
        if !BlsEx.verify_signature?(a.signer, bin, a.signature), do: throw(%{error: :invalid_signature})

        %{error: :ok}
        catch
            :throw,r -> r
            e,r -> IO.inspect {Attestation, :validate, e, r}; %{error: :unknown}
        end
    end

    def validate_vs_chain(a) do
        entry = Fabric.entry_by_hash(a.entry_hash)
        if entry do
            trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))
            if !!trainers and a.signer in trainers do
                true
            end
        end
    end
end

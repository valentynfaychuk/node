defmodule Block do
    def validate_shell(block_packed) do
        try do
        block_size = Application.fetch_env!(:ama, :block_size)
        if byte_size(block_packed) >= block_size, do: throw(%{error: :too_large})
        
        bp = Block.unwrap(block_packed)
        
        if !JCS.validate(bp.block_encoded), do: throw(%{error: :json_not_canonical})
        hash = bp.hash |> Base58.decode
        signature = bp.signature |> Base58.decode

        if hash != Blake3.hash(bp.block_encoded), do: throw(%{error: :invalid_hash})
        if !:public_key.verify(hash, :ignored, signature, {:ed_pub, :ed25519, Base58.decode(bp.block.trainer)}), do: throw(%{error: :invalid_signature})
        if !is_integer(bp.block.height), do: throw(%{error: :height_not_integer})
        if !is_integer(bp.block.prev_height), do: throw(%{error: :prev_height_not_integer})
        if !is_binary(bp.block.prev_hash), do: throw(%{error: :prev_hash_not_binary})
        if !is_binary(bp.block.proof_of_history), do: throw(%{error: :proof_of_history_not_binary})
        if !is_binary(bp.block.vrf_signature), do: throw(%{error: :vrf_signature_not_binary})
        if !is_binary(bp.block.mutation_root), do: throw(%{error: :mutation_root_not_binary})
        if !is_binary(bp.block.mutation_root), do: throw(%{error: :mutation_root_not_binary})
        if !is_binary(bp.block.trainer), do: throw(%{error: :trainer_not_binary})
        if !is_map(bp.block.vdf), do: throw(%{error: :vdf_not_map})
        if !is_list(bp.block.transactions), do: throw(%{error: :transactions_not_list})

        if bp.block.height == 0, do: throw(%{error: :ok})
        if (bp.block.height - 1) != bp.block.prev_height, do: throw(%{error: :invalid_prev_height})

        Enum.each(bp.block.transactions, fn(tx_encoded)->
            %{error: err} = TX.validate(tx_encoded)
            if err != :ok, do: throw(err)

            txp = TX.unwrap(tx_encoded)
            if bp.block.height > (txp.tx.height+100_000), do: throw(%{error: :stale_tx_height})
        end)

        throw(%{error: :ok})
        catch
            :throw,r -> r
            e,r ->
                IO.inspect {Blockchain, :validate_block, e, r}
                %{error: :unknown}
        end
    end

    def validate(block_packed) do
        try do
        %{error: err} = validate_shell(block_packed)
        if err != :ok, do: throw(err)

        bu = Block.unwrap(block_packed)

        if bu.block.height == 0, do: throw(%{error: :ok})

        lb = Blockchain.block_by_height(bu.block.prev_height)
        if !lb, do: throw(%{error: :no_last_block})
        if lb.hash != bu.block.prev_hash, do: throw(%{error: :no_last_block_by_hash})

        lb_poh = Base58.encode(Blake3.hash(Base58.decode(lb.block.proof_of_history)))
        if lb_poh != bu.block.proof_of_history, do: throw(%{error: :invalid_proof_of_history})

        lb_signature = Base58.decode(lb.block.vrf_signature)
        if !:public_key.verify(lb_signature, :ignored, Base58.decode(bu.block.vrf_signature), {:ed_pub, :ed25519, Base58.decode(bu.block.trainer)}), 
            do: throw(%{error: :invalid_vrf})

        #TODO: VDF

        throw(%{error: :ok})
        catch
            :throw,r -> r
            e,r ->
                IO.inspect {Blockchain, :validate_block, e, r}
                %{error: :unknown}
        end
    end

    def shell_from_head() do
        pk_raw = Application.fetch_env!(:ama, :trainer_pk)
        sk_raw = Application.fetch_env!(:ama, :trainer_sk)
        pk = Application.fetch_env!(:ama, :trainer_pk_b58)

        %{block: lb, hash: lb_hash} = Blockchain.block_last()
        proof_of_history = Blake3.hash(lb.proof_of_history |> Base58.decode) |> Base58.encode()
        vrf_signature = :public_key.sign(lb.vrf_signature |> Base58.decode, :ignored, {:ed_pri, :ed25519, pk_raw, sk_raw}, []) |> Base58.encode()

        %{
            trainer: pk,
            height: lb.height + 1,
            prev_height: lb.height,
            prev_hash: lb_hash,
            proof_of_history: proof_of_history,
            vrf_signature: vrf_signature,
            vdf: %{},
        }
    end

    def unwrap(block_packed) do
        [hash, block_packed] = :binary.split(block_packed, ".")
        [signature, block_encoded] = :binary.split(block_packed, ".")
        block = JSX.decode!(block_encoded, labels: :attempt_atom)
        %{block: block, block_encoded: block_encoded, 
            signature: signature, signature_raw: Base58.decode(signature), 
            hash: hash, hash_raw: Base58.decode(hash)}
    end

    def wrap(bu) do
        <<bu.hash::binary,".",bu.signature::binary,".",bu.block_encoded::binary>>
    end
end

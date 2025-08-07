defmodule BIC.Sol do
    import ConsensusKV

    def unpack(sol = <<epoch::32-little, _::binary>>) when epoch >= 156 do
        <<epoch::32-little, segment_vr_hash::32-binary, sol_pk::48-binary, pop::96-binary, computor_pk::48-binary, nonce::12-binary, tensor_c::1024-binary>> = sol
        %{epoch: epoch, pk: sol_pk, pop: pop, computor: computor_pk, segment_vr_hash: segment_vr_hash, tensor_c: tensor_c}
    end
    def unpack(sol = <<epoch::32-little, _::binary>>) when epoch >= 1 do
        <<epoch::32-little, sol_pk::48-binary, pop::96-binary, computor_pk::48-binary, segment_vr::96-binary, _::binary>> = sol
        %{epoch: epoch, pk: sol_pk, pop: pop, computor: computor_pk, segment_vr: segment_vr}
    end
    def unpack(sol) do
        <<epoch::32-little, sol_pk::48-binary, pop::96-binary, computor_pk::48-binary, _::binary>> = sol
        %{epoch: epoch, pk: sol_pk, pop: pop, computor: computor_pk}
    end

    def verify_hash(epoch, hash) when epoch >= 244 do
        <<a, b, c, _::binary>> = hash
        a == 0 and b == 0 and c == 0
    end
    def verify_hash(epoch, hash) when epoch >= 156 do
        <<a, b, _::30-binary>> = hash
        a == 0 and b == 0
    end
    def verify_hash(epoch, hash) when epoch >= 1 do
        <<a, b, _::30-binary>> = hash
        a == 0 and b == 0
    end
    def verify_hash(_epoch, hash) do
        <<a, _::31-binary>> = hash
        a == 0
    end

    def verify(sol = <<epoch::32-little, _::binary>>, hash) when epoch >= 156 do
        if byte_size(sol) != 1024+240, do: throw(%{error: :invalid_sol_seed_size})
        verify_hash(epoch, hash) and Blake3.freivalds(sol)
    end
    def verify(sol = <<epoch::32-little, _::binary>>) when epoch >= 156 do
        if byte_size(sol) != 1024+240, do: throw(%{error: :invalid_sol_seed_size})
        #if kv_get("bic:epoch:segment_vr_hash") != segment_vr_hash, do: throw %{error: :segment_vr_hash}
        verify_hash(epoch, Blake3.hash(sol)) and Blake3.freivalds(sol)
    end
    def verify(sol = <<epoch::32-little, _::192-binary, _segment_vr::96-binary, _::binary>>) when epoch >= 1 do
        if byte_size(sol) != 320, do: throw(%{error: :invalid_sol_seed_size})
        #if kv_get("bic:epoch:segment_vr") != segment_vr, do: throw %{error: :segment_vr}
        verify_cache(UPOW1, sol)
    end
    def verify(sol = <<epoch::32-little, _::binary>>) do
        if byte_size(sol) != 256, do: throw(%{error: :invalid_sol_seed_size})
        verify_cache(UPOW0, sol)
    end

    def verify_cache(module, sol = <<epoch::32-little, _::binary>>) do
        isVerified = :ets.lookup_element(SOLVerifyCache, sol, 2, nil)
        if isVerified == :valid do
            :ets.delete(SOLVerifyCache, sol)
            true
        else
            hash = module.calculate(sol)
            verify_hash(epoch, hash)
        end
    end
end

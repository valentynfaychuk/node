defmodule BIC.Migrate do
    import ConsensusKV

    def migrate(103) do
        kv_get_prefix("")
        |> Enum.each(fn({k,v})->
            cond do
                String.starts_with?(k, "bic:base:nonce:") ->
                    kv_delete(k)
                    value = :erlang.integer_to_binary(v)
                    kv_put2(k, value)
                String.starts_with?(k, "bic:coin:balance:") ->
                    kv_delete(k)
                    key = k <> ":AMA"
                    value = :erlang.integer_to_binary(v)
                    kv_put2(key, value)
                String.starts_with?(k, "bic:epoch:emission_address:") ->
                    kv_delete(k)
                    kv_put2(k, v)
                String.starts_with?(k, "bic:epoch:pop:") ->
                    kv_delete(k)
                    kv_put2(k, v)
                String.starts_with?(k, "bic:epoch:segment_vr") ->
                    kv_delete(k)
                    kv_put2(k, v)
                String.starts_with?(k, "bic:epoch:solutions:") ->
                    kv_delete(k)
                    kv_put2(k, v)
                String.starts_with?(k, "bic:epoch:trainers:removed:") ->
                    nil
                String.starts_with?(k, "bic:epoch:trainers:height:") ->
                    nil
                String.starts_with?(k, "bic:epoch:trainers:") ->
                    nil
                true ->
                    IO.puts Util.hexdump(k)
                    IO.puts "migration failed"
                    throw(%{error: :migration_filade})
            end
        end)
    end

    def migrate(_epoch) do nil end
end
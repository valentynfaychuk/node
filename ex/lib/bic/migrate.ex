defmodule BIC.Migrate do
    import ConsensusKV

    def test() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get_prefix "", %{db: db, cf: cf.contractstate}
        |> Enum.each(fn({k,v})->
            #IO.puts Util.hexdump(k)
            File.write!("/tmp/dump", Util.hexdump(k), [:append])
            File.write!("/tmp/dump", v, [:append])
        end)
    end

    def migrate(103) do
        kv_get_prefix("")
        |> Enum.each(fn({k,v})->
            cond do
                String.starts_with?(k, "bic:base:nonce:") ->
                    kv_delete(k)
                    value = :erlang.integer_to_binary(v)
                    kv_put(k, value)
                String.starts_with?(k, "bic:coin:balance:") ->
                    kv_delete(k)
                    key = k <> ":AMA"
                    value = :erlang.integer_to_binary(v)
                    kv_put(key, value)
                String.starts_with?(k, "bic:epoch:emission_address:") ->
                    kv_delete(k)
                    kv_put(k, v)
                String.starts_with?(k, "bic:epoch:pop:") ->
                    kv_delete(k)
                    kv_put(k, v)
                String.starts_with?(k, "bic:epoch:segment_vr") ->
                    kv_delete(k)
                    kv_put(k, v)
                String.starts_with?(k, "bic:epoch:solutions:") ->
                    kv_delete(k)
                    kv_put(k, v)
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
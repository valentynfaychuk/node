defmodule API.Contract do
    def get(key, parse_type \\ nil) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        opts = %{db: db, cf: cf.contractstate}
        opts = if parse_type != nil do Map.put(opts, parse_type, true) else opts end
        RocksDB.get(key, opts)
    end

    def get_prefix(prefix, parse_type \\ nil) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        opts = %{db: db, cf: cf.contractstate}
        opts = if parse_type != nil do Map.put(opts, parse_type, true) else opts end
        RocksDB.get_prefix(prefix, opts)
    end

    def view(account, function, args) do
    end

    def validate_bytecode(bytecode) do
        task = Task.async(fn -> BIC.Contract.validate(bytecode) end)
        try do
          err = %{error: _} = Task.await(task, 100)
          err
        catch
          :exit, {:timeout, _} ->
            Task.shutdown(task, :brutal_kill)
            %{error: :system, reason: :timeout}
        end
    end
end

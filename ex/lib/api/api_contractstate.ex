defmodule API.ContractState do
    def get(key) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(key, %{db: db, cf: cf.contractstate, term: true})
    end

    def get_prefix(prefix) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get_prefix(prefix, %{db: db, cf: cf.contractstate, term: true})
    end
end
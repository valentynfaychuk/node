defmodule Testnet do
  def call(sk, contract, function, args, attach_symbol \\ nil, attach_amount \\ nil) do
    packed_tx = TX.build(sk, contract, function, args, nil, attach_symbol, attach_amount)
    API.TX.submit_and_wait(packed_tx, false)
  end

  def read(key) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    RocksDB.get(key, %{db: db, cf: cf.contractstate})
  end
end

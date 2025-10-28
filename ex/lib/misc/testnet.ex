defmodule Testnet do
  def call(sk, contract, function, args, attach_symbol \\ nil, attach_amount \\ nil) do
    packed_tx = TX.build(sk, contract, function, args, nil, attach_symbol, attach_amount)
    API.TX.submit_and_wait(packed_tx, false)
  end

  def read(key) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    RocksDB.get(key, %{db: db, cf: cf.contractstate})
  end

  def slash_trainer() do
    trainers = Consensus.trainers_for_height(Consensus.chain_height()+1)
    signer_pk = List.first(trainers)
    signer_sk = Application.fetch_env!(:ama, :keys_by_pk)[signer_pk].seed
    malicious_pk = List.last(trainers)

    msg = <<"slash_trainer", 0::32-little, malicious_pk::binary>>
    signature = BlsEx.sign!(signer_sk, msg, BLS12AggSig.dst_motion())

    ma = BLS12AggSig.new(trainers, signer_pk, signature)

    args = ["0", malicious_pk, signature, "#{bit_size(ma.mask)}", Util.pad_bitstring_to_bytes(ma.mask)]

    Testnet.call(signer_sk, "Epoch", "slash_trainer", args)
  end
end

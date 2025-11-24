defmodule Testnet do
  def call(sk, contract, function, args, attach_symbol \\ nil, attach_amount \\ nil) do
    txu = TX.build(sk, contract, function, args, nil, attach_symbol, attach_amount)
    API.TX.submit_and_wait(txu |> TX.pack(), false)
  end

  def read(key) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    RocksDB.get(key, %{db: db, cf: cf.contractstate})
  end

  def slash_trainer(signer_count \\ 1) do
    validators = DB.Chain.validators_for_height(DB.Chain.height()+1)
    malicious_pk = List.last(validators)
    validators_signing = DB.Chain.validators_for_height_my(DB.Chain.height()+1) |> Enum.take(signer_count)

    aggsig = BLS12AggSig.new_padded(length(validators))
    aggsig = Enum.reduce(validators_signing, aggsig, fn(signer_pk, aggsig)->
      msg = <<"slash_trainer", 0::32-little, malicious_pk::binary>>
      seed = Application.fetch_env!(:ama, :keys_by_pk)[signer_pk].seed
      signature = BlsEx.sign!(seed, msg, BLS12AggSig.dst_motion())
      BLS12AggSig.add_padded(aggsig, validators, signer_pk, signature)
    end)

    args = ["0", malicious_pk, aggsig.aggsig, "#{aggsig.mask_size}", aggsig.mask]

    signer_sk = Application.fetch_env!(:ama, :trainer_sk)
    Testnet.call(signer_sk, "Epoch", "slash_trainer", args)
  end
end

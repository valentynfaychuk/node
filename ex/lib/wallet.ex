defmodule Wallet do
    def balance() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        coins = Consensus.chain_balance(pk)
        BIC.Coin.from_flat(coins)
    end

    def transfer(to, amount) do
        to = if byte_size(to) != 48, do: Base58.encode(to), else: to
        sk = Application.fetch_env!(:ama, :trainer_sk)
        tx_packed = TX.build(sk, "Coin", "transfer", [to, BIC.Coin.to_flat(amount)])
        TXPool.insert(tx_packed)
        NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
    end
end
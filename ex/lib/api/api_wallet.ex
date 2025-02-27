defmodule API.Wallet do
    def balance() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        balance(pk)
    end

    def balance(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
        coins = Consensus.chain_balance(pk)
        %{flat: coins, float: BIC.Coin.from_flat(coins)}
    end

    def transfer(to, amount) do
        sk = Application.fetch_env!(:ama, :trainer_sk)
        transfer(sk, to, amount)
    end

    def transfer(from_sk, to, amount) do
        from_sk = if byte_size(from_sk) != 64, do: Base58.decode(from_sk), else: from_sk
        to = if byte_size(to) != 48, do: Base58.decode(to), else: to
        amount = if is_float(amount) do trunc(amount * 1_000_000_000) else amount end
        tx_packed = TX.build(from_sk, "Coin", "transfer", [to, amount])
        TXPool.insert(tx_packed)
        NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
    end

    def generate_key() do
        sk = :crypto.strong_rand_bytes(64)
        pk = BlsEx.get_public_key!(sk)
        {Base58.encode(pk), Base58.encode(sk)}
    end
end
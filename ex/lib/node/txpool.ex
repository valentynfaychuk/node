defmodule TXPool do
    def init() do
        :ets.new(TXPool, [:ordered_set, :named_table, :public,
            {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
    end

    def insert(tx_packed) do
        txu = TX.unwrap(tx_packed)
        :ets.insert(TXPool, {txu.hash, txu})
    end

    def purge_stale() do
        :ets.tab2list(TXPool)
        |> Enum.each(fn {key, txu} ->
            if is_stale(txu) do
                :ets.delete(TXPool, key)
            end
        end)
    end

    def grab_next_valids(next_entry) do
        :ets.tab2list(TXPool)
        |> Enum.filter(fn({key, txu}) ->
            heightValid = abs(next_entry.header_unpacked.height - txu.tx.height) < 100_000
            chainValid = TX.chain_valid(TX.wrap(txu))
            heightValid and chainValid
        end)
        |> Enum.map(& TX.wrap(elem(&1,1)))
        |> case do
            [] -> []
            txs -> 
                Enum.shuffle(txs)
                |> Enum.take(1)
        end
    end

    def is_stale(txu) do
        entry = Fabric.rooted_tip_entry()

        tx_stale_height = abs(entry.header_unpacked.height - txu.tx.height) >= 100_000
        tx_processed = txu.tx.nonce <= Consensus.chain_nonce(txu.tx.signer)

        cond do
            tx_stale_height -> true
            tx_processed -> true
            true -> false
        end
    end

    def random() do
        :ets.tab2list(TXPool)
        |> case do
            [] -> nil
            txs -> Enum.random(txs) |> elem(1)
        end
    end

    def test() do
        {pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
        packed_tx = TX.build_transaction(sk, 1, "Epoch", "submit_sol", [<<>>])

        TX.validate(packed_tx)
        TXPool.insert(packed_tx)
    end

    def test2() do
        sk_raw = Application.fetch_env!(:ama, :trainer_sk_raw)
        pk = Base58.encode(:crypto.strong_rand_bytes(48))
        packed_tx = TX.build_transaction(sk_raw, 110_000, "Coin", "transfer", [pk, 1])
        TXPool.insert(packed_tx)
    end
end
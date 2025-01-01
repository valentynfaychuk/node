defmodule TXPool do
    def init() do
        :ets.new(TXPool, [:ordered_set, :named_table, :public,
            {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
    end

    def insert(tx_packed) do
        txp = TX.unwrap(tx_packed)
        :ets.insert(TXPool, {txp.hash, txp})
    end

    def purge_stale() do
        :ets.tab2list(TXPool)
        |> Enum.each(fn {key, txu} ->
            if is_stale(TX.wrap(txu)) do
                :ets.delete(TXPool, key)
            end
        end)
    end

    def take_for_block(block_height) do
        block_txs_max_size = 1024
        :ets.tab2list(TXPool)
        |> Enum.map(& elem(&1,1))
        |> Enum.reduce_while({block_txs_max_size, []}, fn(txu, {bytes_left, acc})->
            tx_packed = TX.wrap(txu)
            new_bytes_left = bytes_left - byte_size(tx_packed)
            cond do
                new_bytes_left < 0 -> {:halt, {bytes_left, acc}}
                true -> {:cont, {new_bytes_left, acc ++ [tx_packed]}}
            end
        end)
        |> elem(1)
        |> Enum.reject(fn(tx_packed)->
            txu = TX.unwrap(tx_packed)
            :ets.member(:tx_result, txu.hash)
            or :ets.match_object(:tx_delayed, {{:_, txu.hash}, :_}) != []
            or block_height > (txu.tx.height+100_000)
            #or BIC.Coin.balance(txp.tx.signer) < BIC.Coin.to_flat(10)
        end)
        |> Enum.take(1)
    end

    def random() do
        :ets.tab2list(TXPool)
        |> Enum.map(& elem(&1,1))
        |> case do
            [] -> nil
            list -> Enum.random(list)
        end
    end

    def is_stale(tx_packed) do
        txp = TX.unwrap(tx_packed)

        %{block: block} = Blockchain.block_last()

        tx_old_height = block.height > (txp.tx.height+100_000)
        tx_processed = :ets.member(:tx_result, txp.hash)
        tx_delayed = :ets.match_object(:tx_delayed, {:_, txp.hash}) != []

        cond do
            tx_old_height -> true
            tx_processed -> true
            tx_delayed -> true
            true -> false
        end
    end

    def test() do
        {pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
        packed_tx = TX.build_transaction(sk, 1, "Trainer", "submit_sol", [<<>>])
        TX.validate(packed_tx)
        TXPool.insert(packed_tx)
    end
end
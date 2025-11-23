defmodule TXPool do
    def insert(tx_packed) when is_binary(tx_packed) do insert([tx_packed]) end
    def insert([]) do :ok end
    def insert(txs_packed) do
        txus = Enum.map(txs_packed, fn(tx_packed)->
            txu = TX.unpack(tx_packed)
            {{txu.tx.nonce, txu.hash}, txu}
        end)
        :ets.insert(TXPool, txus)
    end

    def delete_packed(tx_packed) when is_binary(tx_packed) do delete_packed([tx_packed]) end
    def delete_packed([]) do :ok end
    def delete_packed(txs_packed) do
        Enum.each(txs_packed, fn(tx_packed)->
            txu = TX.unpack(tx_packed)
            :ets.delete(TXPool, {txu.tx.nonce, txu.hash})
        end)
    end

    def insert_and_broadcast(tx_packed, opts \\ %{}) do
      TXPool.insert(tx_packed)
      NodeGen.broadcast(NodeProto.event_tx(tx_packed), opts)
      NodeGen.broadcast(NodeProto.event_tx2(tx_packed), opts)
    end

    def purge_stale() do
        cur_epoch = DB.Chain.epoch()
        :ets.tab2list(TXPool)
        |> Enum.each(fn {key, txu} ->
            if is_stale(txu, cur_epoch) do
                :ets.delete(TXPool, key)
            end
        end)
    end

    def validate_tx(txu, args \\ %{}) do
      chain_epoch = Map.get_lazy(args, :epoch, fn()-> DB.Chain.epoch() end)
      chain_segment_vr_hash = Map.get_lazy(args, :segment_vr_hash, fn()-> DB.Chain.segment_vr_hash() end)
      chain_diff_bits = Map.get_lazy(args, :diff_bits, fn()-> DB.Chain.diff_bits() end)
      batch_state = Map.get_lazy(args, :batch_state, fn()-> %{} end)

      try do
        chainNonce = Map.get_lazy(batch_state, {:chain_nonce, txu.tx.signer}, fn()-> DB.Chain.nonce(txu.tx.signer) end)
        nonceValid = !chainNonce or txu.tx.nonce > chainNonce
        if !nonceValid, do: throw(%{error: :invalid_tx_nonce, key: {txu.tx.nonce, txu.hash}})
        batch_state = Map.put(batch_state, {:chain_nonce, txu.tx.signer}, txu.tx.nonce)

        balance = Map.get_lazy(batch_state, {:balance, txu.tx.signer}, fn()-> DB.Chain.balance(txu.tx.signer) end)
        balance = balance - BIC.Base.exec_cost(chain_epoch, txu)
        balance = balance - BIC.Coin.to_cents(1)
        if balance < 0, do: throw(%{error: :not_enough_tx_exec_balance, key: {txu.tx.nonce, txu.hash}})
        batch_state = Map.put(batch_state, {:balance, txu.tx.signer}, balance)

        hasSol = Enum.find_value(txu.tx.actions, fn(a)-> a.function == "submit_sol" and hd(a.args) end)
        epochSolValid = if !hasSol do true else
          <<sol_epoch::32-little, sol_svrh::32-binary, _::binary>> = hasSol

          chain_epoch == sol_epoch
          and chain_segment_vr_hash == sol_svrh
          and byte_size(hasSol) == BIC.Sol.size()
        end
        if !epochSolValid, do: throw(%{error: :invalid_tx_sol, key: {txu.tx.nonce, txu.hash}})

        %{error: :ok, batch_state: batch_state}
      catch
        :throw, r -> r
      end
    end

    def validate_tx_batch(tx_packed) when is_binary(tx_packed) do validate_tx_batch([tx_packed]) end
    def validate_tx_batch(txs_packed) when is_list(txs_packed) do
      chain_epoch = DB.Chain.epoch()
      segment_vr_hash = DB.Chain.segment_vr_hash()
      diff_bits = DB.Chain.diff_bits()

      {good, _} = Enum.reduce(txs_packed, {[], %{}}, fn(tx_packed, {acc, batch_state})->
        case TX.validate(tx_packed, TX.unpack(tx_packed)) do
          %{error: :ok, txu: txu} ->
            case TXPool.validate_tx(txu, %{epoch: chain_epoch, segment_vr_hash: segment_vr_hash, diff_bits: diff_bits, batch_state: batch_state}) do
              %{error: :ok, batch_state: batch_state} -> {acc ++ [tx_packed], batch_state}
              %{error: error} -> {acc, batch_state}
            end
          _ -> {acc, batch_state}
        end
      end)

      good
    end

    def grab_next_valid(amt \\ 1) do
        try do
            chain_epoch = DB.Chain.epoch()
            segment_vr_hash = DB.Chain.segment_vr_hash()
            {acc, state} = :ets.foldl(fn({key, txu}, {acc, state_old})->
                try do
                  case validate_tx(txu, %{epoch: chain_epoch, segment_vr_hash: segment_vr_hash, batch_state: state_old}) do
                    %{error: :ok, batch_state: batch_state} ->
                      acc = acc ++ [TX.pack(txu)]
                      if length(acc) == amt do
                          throw {:choose, acc}
                      end
                      {acc, batch_state}
                    #delete stale
                    %{key: key} ->
                      :ets.delete(TXPool, key)
                      {acc, state_old}
                  end
                catch
                    :throw,{:choose, txs_packed} -> throw {:choose, txs_packed}
                end
            end, {[], %{}}, TXPool)
            acc
        catch
            :throw,{:choose, txs_packed} -> txs_packed
        end
    end

    def is_stale(txu, cur_epoch) do
        chainNonce = DB.Chain.nonce(txu.tx.signer)
        nonceValid = !chainNonce or txu.tx.nonce > chainNonce

        hasSol = Enum.find_value(txu.tx.actions, fn(a)-> a.function == "submit_sol" and hd(a.args) end)
        epochSolValid = if !hasSol do true else
            <<sol_epoch::32-little, _::binary>> = hasSol
            cur_epoch == sol_epoch
        end

        cond do
            !epochSolValid -> true
            !nonceValid -> true
            true -> false
        end
    end

    def random(amount \\ 2) do
        :ets.tab2list(TXPool)
        |> case do
            [] -> nil
            txs ->
                Enum.take(txs, amount)
                |> Enum.map(fn{_, txu}-> TX.pack(txu) end)
        end
    end

    def lowest_nonce(pk) do
        :ets.tab2list(TXPool)
        |> Enum.reduce(nil, fn({{nonce, _hash}, txu}, lowest_nonce) ->
            if txu.tx.signer == pk do
                cond do
                    lowest_nonce == nil -> nonce
                    nonce < lowest_nonce -> nonce
                    true -> lowest_nonce
                end
            else
                lowest_nonce
            end
        end)
    end

    def highest_nonce() do
        Application.fetch_env!(:ama, :trainer_pk)
        |> highest_nonce()
    end
    def highest_nonce(pk) do
        :ets.tab2list(TXPool)
        |> Enum.reduce({nil, 0}, fn({{nonce, _hash}, txu}, {highest_nonce, cnt})->
            cond do
                txu.tx.signer == pk and (highest_nonce == nil or nonce > highest_nonce) -> {nonce, cnt + 1}
                txu.tx.signer == pk -> {highest_nonce, cnt + 1}
                true -> {highest_nonce, cnt}
            end
        end)
    end

    def size() do
      :ets.info(TXPool, :size)
    end
end

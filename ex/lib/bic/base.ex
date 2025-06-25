defmodule BIC.Base do
    import ConsensusKV

    def exec_cost(txu) do
        bytes = byte_size(txu.tx_encoded) + 32 + 96
        BIC.Coin.to_cents( 3 + div(bytes, 256) * 3 )

        #for future update
        #BIC.Coin.to_tenthousandth( 18 + div(bytes, 256) * 3 )
    end

    defp seed_random(vr, txhash, action_index, call_cnt) do
        seed_bin = <<seed::256-little>> = Blake3.hash(
            <<vr::binary, txhash::binary, action_index::binary, call_cnt::binary>>)
        :rand.seed(:exsss, seed)
        seed_bin
    end

    def call_txs_pre_parallel(env, txus) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)

        Enum.each(txus, fn(txu)->
            kv_put("bic:base:nonce:#{txu.tx.signer}", txu.tx.nonce, %{to_integer: true})
            exec_cost = exec_cost(txu)
            kv_increment("bic:coin:balance:#{txu.tx.signer}:AMA", -exec_cost)
            kv_increment("bic:coin:balance:#{env.entry_signer}:AMA", exec_cost)
        end)

        {Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
    end

    def call_exit(env) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)
        seed_random(env.entry_vr, "", "", "")

        #thank you come again
        kv_increment("bic:coin:balance:#{env.entry_signer}:AMA", BIC.Coin.to_flat(1))

        if rem(env.entry_height, 1000) == 0 do
            kv_put("bic:epoch:segment_vr_hash", Blake3.hash(env.entry_vr))
        end

        cond do
            env.entry_height == 0 ->
                kv_put("bic:epoch:trainers:0", [env.entry_signer], %{term: true})
                kv_put("bic:epoch:pop:#{env.entry_signer}", EntryGenesis.pop())
            rem(env.entry_height, 100_000) == 99_999 ->
                BIC.Epoch.next(env)
            true -> :ok
        end

        {Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
    end

    def call_tx_actions(env, txu) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)

        result = try do
            action = List.first(txu.tx.actions)
            if !action, do: throw(%{error: :no_actions})

            env = Map.put(env, :account_current, action.contract)
            if BlsEx.validate_public_key(action.contract) do
            else
                seed_random(env.entry_vr, env.tx_hash, "0", "")
                contract = "Elixir.BIC.#{action.contract}"
                module = String.to_existing_atom(contract)
                function = String.to_existing_atom(action.function)

                :erlang.apply(module, :call, [function, env, action.args])
            end
            %{error: :ok}
        catch
            :throw,r -> r
            e,r ->
                IO.inspect {:tx_error, e, r, __STACKTRACE__}
                %{error: :unknown}
        end

        {Process.get(:mutations, []), Process.get(:mutations_reverse, []), result}
    end
end

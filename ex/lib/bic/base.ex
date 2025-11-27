defmodule BIC.Base do
    import ConsensusKV

    def seed_random(vr, txhash, action_index, call_cnt) do
        seed_bin = <<seed::256-little>> = Blake3.hash(
            <<vr::binary, txhash::binary, action_index::binary, call_cnt::binary>>)
        :rand.seed(:exsss, seed)
        seed_bin
    end

    def call_exit(env) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)
        seed_random(env.entry_vr, "", "", "")

        if rem(env.entry_height, 1000) == 0 do
            kv_put("bic:epoch:segment_vr_hash", Blake3.hash(env.entry_vr))
        end

        cond do
            env.entry_height == 0 ->
                kv_put("bic:epoch:validators:height:000000000000", [env.entry_signer], %{term: true})
                kv_put("account:#{env.entry_signer}:attribute:pop", EntryGenesis.pop())
            rem(env.entry_height, 100_000) == 99_999 ->
                BIC.Epoch.next(env)
            true -> :ok
        end

        {Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
    end

    def valid_bic_action(contract, function) do
      contract in ["Epoch", "Coin", "Contract"]
      and function in ["submit_sol", "transfer", "set_emission_address", "slash_trainer", "deploy", "create_and_mint", "mint", "pause"]
    end

    def call_tx_actions(env, txu) do
        Process.delete(:mutations_gas)
        Process.delete(:mutations_gas_reverse)
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)

        result = try do
            action = List.first(txu.tx.actions)
            if !action, do: throw(%{error: :no_actions})

            env = Map.put(env, :account_current, action.contract)
            if BlsEx.validate_public_key(action.contract) do
                bytecode = BIC.Contract.bytecode(action.contract)
                if bytecode do
                    seed = <<float64::64-float, _::binary>> = seed_random(env.entry_vr, env.tx_hash, "0", "#{env.call_counter}")
                    env = Map.put(env, :seed, seed)
                    env = Map.put(env, :seedf64, float64)

                    env = if !action[:attached_symbol] and !action[:attached_amount] do env else
                      env = Map.put(env, :attached_symbol, action.attached_symbol)
                      env = Map.put(env, :attached_amount, action.attached_amount)
                      amount = action.attached_amount
                      amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end

                      if amount <= 0, do: throw(%{error: :invalid_attached_amount})
                      if amount > BIC.Coin.balance(env.tx_signer, action.attached_symbol), do: throw(%{error: :attached_amount_insufficient_funds})

                      kv_increment("bic:coin:balance:#{action.contract}:#{action.attached_symbol}", amount)
                      kv_increment("bic:coin:balance:#{env.tx_signer}:#{action.attached_symbol}", -amount)
                      env
                    end
                    result = BIC.Base.WASM.call(env, bytecode, action.function, action.args)

                    muts = Process.get(:mutations, []); Process.delete(:mutations)
                    muts_rev = Process.get(:mutations_reverse, []); Process.delete(:mutations_reverse)

                    exec_used = (result[:exec_used] || 0) * 100
                    kv_increment("bic:coin:balance:#{env.tx_signer}:AMA", -exec_used)

                    #burn 50% to prevent MEV/FreeChainGrowth attack
                    half_exec_cost = div(exec_used, 2)
                    kv_increment("bic:coin:balance:#{env.entry_signer}:AMA", half_exec_cost)
                    kv_increment("bic:coin:balance:#{BIC.Coin.burn_address()}:AMA", half_exec_cost)

                    Process.put(:mutations_gas, Process.get(:mutations, []))
                    Process.put(:mutations_gas_reverse, Process.get(:mutations_reverse, []))
                    Process.put(:mutations, muts)
                    Process.put(:mutations_reverse, muts_rev)

                    result
                else
                    %{error: :system, reason: :account_has_no_bytecode}
                end
            else
                seed_random(env.entry_vr, env.tx_hash, "0", "")

                if !valid_bic_action(action.contract, action.function), do: throw(%{error: :invalid_bic_action})

                contract = "Elixir.BIC.#{action.contract}"
                module = String.to_existing_atom(contract)
                function = String.to_existing_atom(action.function)

                :erlang.apply(module, :call, [function, env, action.args])
                %{error: :ok}
            end
        catch
            :throw,r -> r
            e,r ->
                IO.inspect {:tx_error, e, r, __STACKTRACE__}
                %{error: :unknown}
        end

        {
          Process.get(:mutations, []), Process.get(:mutations_reverse, []),
          Process.get(:mutations_gas, []), Process.get(:mutations_gas_reverse, []),
          result
        }
    end
end

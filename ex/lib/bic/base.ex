defmodule BIC.Base do
    import ConsensusKV

    def exec_cost(epoch, txu) do
        bytes = byte_size(txu.tx_encoded) + 32 + 96
        BIC.Coin.to_cents( 1 + div(bytes, 1024) * 1 )

        #for future update
        #BIC.Coin.to_tenthousandth( 18 + div(bytes, 256) * 3 )
    end

    def seed_random(vr, txhash, action_index, call_cnt) do
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
            exec_cost = exec_cost(env.entry_epoch, txu)
            kv_increment("bic:coin:balance:#{txu.tx.signer}:AMA", -exec_cost)

            #burn 50% to prevent MEV/FreeChainGrowth attack
            half_exec_cost = div(exec_cost, 2)
            kv_increment("bic:coin:balance:#{env.entry_signer}:AMA", half_exec_cost)
            kv_increment("bic:coin:balance:#{BIC.Coin.burn_address()}:AMA", half_exec_cost)
        end)

        #parallel verify sols
        segment_vr_hash = kv_get("bic:epoch:segment_vr_hash")
        diff_bits = kv_get("bic:epoch:diff_bits", %{to_integer: true}) || 24
        steam = Task.async_stream(txus, fn txu ->
            sol = Enum.find_value(txu.tx.actions, fn(a)-> a.function == "submit_sol" and length(a.args) != [] and hd(a.args) end)
            if sol do
              hash = Blake3.hash(sol)
              opts = %{hash: hash, vr_b3: env.entry_vr_b3, segment_vr_hash: segment_vr_hash, diff_bits: diff_bits}
              valid = try do BIC.Sol.verify(sol, opts) catch _,_ -> false end
              %{hash: hash, valid: valid}
            end
        end)

        sol_verified_cache = for {error, spec} <- steam,
          error == :ok and spec != nil,
          into: %{},
          do: {spec.hash, spec.valid}

        Process.put(SolVerifiedCache, sol_verified_cache)

        {Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
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
                kv_put("bic:epoch:trainers:0", [env.entry_signer], %{term: true})
                kv_put("bic:epoch:pop:#{env.entry_signer}", EntryGenesis.pop())
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
                function = String.to_atom(action.function)

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

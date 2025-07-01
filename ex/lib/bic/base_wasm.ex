defmodule BIC.Base.WASM do
    import ConsensusKV

    def call(mapenv, wasmbytes, function, args) do
        BIC.Base.WASM.Safe.spawn(mapenv, wasmbytes, function, args)
        mapenv = Map.put(mapenv, :attached_symbol, "")
        mapenv = Map.put(mapenv, :attached_amount, "")

        wasm_loop(mapenv, [])
    end

    def wasm_loop(env, callstack) do
        receive do
            #Storage Get
            {:rust_request_storage_kv_get, rpc_id, key} ->
                value = ConsensusKV.kv_get(key)
                value = if value do :erlang.binary_to_list(value) else value end
                :ok = WasmerEx.respond_to_rust_storage_kv_get(rpc_id, value)
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_exists, rpc_id, key} ->
                value = ConsensusKV.kv_exists(key)
                :ok = WasmerEx.respond_to_rust_storage_kv_exists(rpc_id, value)
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_get_prev, rpc_id, suffix, key} ->
                {v1,v2} = ConsensusKV.kv_get_prev(suffix, key)
                {v1,v2} = if v1 do {:erlang.binary_to_list(v1),:erlang.binary_to_list(v2)} else {v1,v2} end
                :ok = WasmerEx.respond_to_rust_storage_kv_get_prev_next(rpc_id, {v1,v2})
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_get_next, rpc_id, suffix, key} ->
                {v1,v2} = ConsensusKV.kv_get_next(suffix, key)
                {v1,v2} = if v1 do {:erlang.binary_to_list(v1),:erlang.binary_to_list(v2)} else {v1,v2} end
                :ok = WasmerEx.respond_to_rust_storage_kv_get_prev_next(rpc_id, {v1,v2})
                __MODULE__.wasm_loop(env, callstack)

            #Storage Put
            {:rust_request_storage_kv_put, rpc_id, key, value} ->
                ConsensusKV.kv_put(key, value)
                :ok = WasmerEx.respond_to_rust_storage(rpc_id, "" |> :erlang.binary_to_list())
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_increment, rpc_id, key, value} ->
                new_value = ConsensusKV.kv_increment(key, value)
                :ok = WasmerEx.respond_to_rust_storage(rpc_id, new_value |> :erlang.binary_to_list())
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_delete, rpc_id, key} ->
                ConsensusKV.kv_delete(key)
                :ok = WasmerEx.respond_to_rust_storage(rpc_id, "" |> :erlang.binary_to_list())
                __MODULE__.wasm_loop(env, callstack)
            {:rust_request_storage_kv_clear, rpc_id, prefix} ->
                deleted_count = ConsensusKV.kv_clear(prefix)
                :ok = WasmerEx.respond_to_rust_storage(rpc_id, deleted_count |> :erlang.binary_to_list())
                __MODULE__.wasm_loop(env, callstack)

            #no cross-contract calls yet
            #{:rust_request_call, rpc_id, exec_remaining, contract, function, args} ->
            #    :ok = WasmerEx.respond_to_rust_call(rpc_id, "system", [], 0, "readonly")
            #    __MODULE__.wasm_loop(env, callstack)

            {:rust_request_call, rpc_id, exec_remaining, contract, function, args, {attached_symbol, attached_amount}} ->
                IO.inspect {:rust_request_call, rpc_id, exec_remaining, contract, function, args, {attached_symbol, attached_amount}}
                cond do
                #BlsEx.validate_public_key(contract) ->
                #XCC current disabled
                false ->
                    bytecode = BIC.Contract.bytecode(contract)
                    if bytecode do
                        env = Map.put(env, :call_counter, env.call_counter + 1)
                        seed = <<float64::64-float, _::binary>> = BIC.Base.seed_random(env.entry_vr, env.tx_hash, "0", "#{env.call_counter}")
                        env = Map.put(env, :seed, seed)
                        env = Map.put(env, :seedf64, float64)

                        if attached_symbol != "" and attached_amount != "" do
                          amount = try do
                            if is_binary(attached_amount) do :erlang.binary_to_integer(attached_amount) else attached_amount end
                          catch _,_ -> nil end
                          cond do
                            !amount or amount <= 0 ->
                              :ok = WasmerEx.respond_to_rust_call(rpc_id, "system" |> :erlang.binary_to_list(), [], exec_remaining, "invalid_attached_amount" |> :erlang.binary_to_list())
                              __MODULE__.wasm_loop(env, callstack)
                            amount > BIC.Coin.balance(env.account_current, attached_symbol) ->
                              :ok = WasmerEx.respond_to_rust_call(rpc_id, "system" |> :erlang.binary_to_list(), [], exec_remaining, "attached_amount_insufficient_funds" |> :erlang.binary_to_list())
                              __MODULE__.wasm_loop(env, callstack)
                            true ->
                              env = Map.put(env, :attached_symbol, attached_symbol)
                              env = Map.put(env, :attached_amount, attached_amount)

                              kv_increment("bic:coin:balance:#{contract}:#{attached_symbol}", amount)
                              kv_increment("bic:coin:balance:#{env.account_current}:#{attached_symbol}", -amount)

                              last_account = env.account_current
                              last_caller = env.account_caller
                              env = Map.put(env, :account_current, contract)
                              env = Map.put(env, :account_caller, last_account)

                              env = Map.put(env, :call_exec_points_remaining, exec_remaining)

                              pid = BIC.Base.WASM.Safe.spawn(env, bytecode, function, args)
                              callstack = callstack ++ [{pid, rpc_id, last_account, last_caller}]
                              __MODULE__.wasm_loop(env, callstack)
                          end
                        else
                          last_account = env.account_current
                          last_caller = env.account_caller
                          env = Map.put(env, :account_current, contract)
                          env = Map.put(env, :account_caller, last_account)

                          env = Map.put(env, :call_exec_points_remaining, exec_remaining)

                          pid = BIC.Base.WASM.Safe.spawn(env, bytecode, function, args)
                          callstack = callstack ++ [{pid, rpc_id, last_account, last_caller}]
                          __MODULE__.wasm_loop(env, callstack)
                        end
                    else
                        :ok = WasmerEx.respond_to_rust_call(rpc_id, "system" |> :erlang.binary_to_list(), [], exec_remaining, "account_has_no_bytecode" |> :erlang.binary_to_list())
                        __MODULE__.wasm_loop(env, callstack)
                    end
                env.readonly ->
                    :ok = WasmerEx.respond_to_rust_call(rpc_id, "system" |> :erlang.binary_to_list(), [], 0, "readonly" |> :erlang.binary_to_list())
                    __MODULE__.wasm_loop(env, callstack)
                true ->
                    env = Map.put(env, :call_counter, env.call_counter + 1)
                    BIC.Base.seed_random(env.entry_vr, env.tx_hash, "0", "#{env.call_counter}")

                    last_account = env.account_current
                    last_caller = env.account_caller
                    env = Map.put(env, :account_current, contract)
                    env = Map.put(env, :account_caller, last_account)

                    result = try do
                        if contract not in ["Epoch", "Coin", "Contract"], do: throw(%{error: :invalid_bic})
                        if function not in ["submit_sol", "transfer", "set_emission_address", "slash_trainer", "deploy"], do: throw %{error: :invalid_function}
                        module = String.to_existing_atom("Elixir.BIC.#{contract}")
                        function = String.to_existing_atom(function)

                        :erlang.apply(module, :call, [function, env, args])
                        %{error: :ok}
                    catch
                        :throw,r -> r
                        e,r ->
                            IO.inspect {:tx_error_nested, e, r, __STACKTRACE__}
                            %{error: :unknown}
                    end

                    env = Map.put(env, :account_current, last_account)
                    env = Map.put(env, :account_caller, last_caller)
                    case result.error do
                        :ok -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "ok" |> :erlang.binary_to_list(), [], exec_remaining, nil)
                        error -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "abort" |> :erlang.binary_to_list(), [], exec_remaining, "#{error}" |> :erlang.binary_to_list())
                    end
                    __MODULE__.wasm_loop(env, callstack)
                end

            {:result, {error, logs, exec_remaining, retv}} when error in [nil, "return_value"]->
                IO.inspect {:good, {error, logs, exec_remaining, retv} }

                if callstack == [] do
                    exec_used = env.call_exec_points - exec_remaining
                    case error do
                        nil -> %{error: :ok, logs: logs, exec_used: exec_used, result: nil}
                        "return_value" -> %{error: :ok, logs: logs, exec_used: exec_used, result: retv}
                        #"abort" -> %{error: :abort, logs: logs, exec_used: exec_used, result: retv}
                        #error -> %{error: :system, logs: logs, exec_used: exec_used, result: error}
                    end
                else
                    [{_pid, rpc_id, last_account, last_caller}|callstack] = callstack
                    case error do
                        nil -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "ok" |> :erlang.binary_to_list(), logs, exec_remaining, nil)
                        "return_value" -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "ok" |> :erlang.binary_to_list(), logs, exec_remaining, retv |> :erlang.binary_to_list())
                        #"abort" -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "abort", logs, exec_remaining, retv)
                        #error -> :ok = WasmerEx.respond_to_rust_call(rpc_id, "system", logs, exec_remaining, error)
                    end
                    env = Map.put(env, :current_account, last_account)
                    env = Map.put(env, :account_caller, last_caller)
                    __MODULE__.wasm_loop(env, callstack)
                end

            #{:result, {error, logs, exec_remaining, _retv}} when error in ["unreachable", "no_elixir_callback", "invalid_memory", "xcc_failed"] ->
            {:result, {error, logs, exec_remaining, retv}} ->
                IO.inspect {:bad, {error, logs, exec_remaining, retv} }
                Enum.each(callstack, fn {pid, _, _, _}-> Process.exit(pid, :brutal_kill) end)
                exec_remaining = if error == "unreachable" do 0 else exec_remaining end
                exec_used = env.call_exec_points - exec_remaining
                if error == "abort" do
                  %{error: :abort, logs: logs, exec_used: exec_used, result: retv}
                else
                  %{error: :system, logs: logs, exec_used: exec_used, result: error}
                end

            {:result, result} ->
                Enum.each(callstack, fn {pid, _, _, _}-> Process.exit(pid, :brutal_kill) end)
                IO.inspect {:unknown_wasm_contract_result, result}
                %{error: :system, logs: [], exec_used: env.call_exec_points, result: "unknown"}

            msg ->
                IO.inspect {:RPCUKN, self(), msg}
                __MODULE__.wasm_loop(env, callstack)
        after
            #TODO: fix this cleanly
            1_000 ->
                Enum.each(callstack, fn {pid, _, _, _}-> Process.exit(pid, :brutal_kill) end)
                %{error: :system, logs: [], exec_used: env.call_exec_points, result: "toplevel_timeout"}
        end
    end
end

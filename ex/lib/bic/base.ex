defmodule BIC.Base do
	import ConsensusKV

	def exec_cost(tx_bytes) do
		bytes = if is_integer(tx_bytes) do tx_bytes else byte_size(tx_bytes) end
		BIC.Coin.to_cents( 3 + div(bytes, 256) * 3 )
	end

	def can_pay_exec_cost(env) do
		tx_bytes = byte_size(env.txu.tx_encoded)
		BIC.Coin.balance(env.txu.tx.signer) >= exec_cost(tx_bytes)
	end

	def call_exit(env) do
		Process.delete(:mutations)
        Process.delete(:mutations_reverse)
		seed_random("", env.entry.header_unpacked.vr)

		signer = env.entry.header_unpacked.signer

        #thank you come again
		kv_increment("bic:coin:balance:#{signer}", BIC.Coin.to_flat(1))

        cond do
        	env.entry.header_unpacked.height == 0 ->
        		kv_put("bic:epoch:trainers:0", [signer])
				kv_put("bic:epoch:pop:#{signer}", EntryGenesis.pop())
        	rem(env.entry.header_unpacked.height, 100_000) == 99_999 -> BIC.Epoch.next(env)
        	true -> :ok
        end

		{Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
	end

	def call_tx_pre(env) do
		Process.delete(:mutations)
        Process.delete(:mutations_reverse)
		seed_random("", env.entry.header_unpacked.vr)

		kv_put("bic:base:nonce:#{env.txu.tx.signer}", env.txu.tx.nonce)
		exec_cost = exec_cost(byte_size(env.txu.tx_encoded))
		kv_increment("bic:coin:balance:#{env.txu.tx.signer}", -exec_cost)
		kv_increment("bic:coin:balance:#{env.entry.header_unpacked.signer}", exec_cost)

		{Process.get(:mutations, []), Process.get(:mutations_reverse, [])}
	end

	def call_tx_actions(env) do
		Process.delete(:mutations)
        Process.delete(:mutations_reverse)

		result = try do
			call_tx_actions_1(env)
			%{error: :ok}
		catch
			:throw,r -> r
			e,r ->
				IO.inspect {:tx_error, e, r, __STACKTRACE__}
				%{error: :unknown}
		end

		{Process.get(:mutations, []), Process.get(:mutations_reverse, []), result}
	end

	defp call_tx_actions_1(%{txu: %{tx: %{actions: []}}}) do nil end
	defp call_tx_actions_1(env = %{txu: %{tx: %{actions: [action|rest]}}}) do
		env = put_in(env, [:txu, :tx, :actions], rest)
		process_tx_2(env, action)
		call_tx_actions_1(env)
	end

	defp seed_random(txhash, vr) do
		<<seed::256-little>> = Blake3.hash(<<txhash::binary, vr::binary>>)
	    :rand.seed(:exsss, seed)
	end

	defp process_tx_2(env, action) do
		seed_random(env.txu.hash_raw, env.entry.header_unpacked.vr)
		module = String.to_existing_atom("Elixir.BIC.#{action.contract}")
		function = String.to_existing_atom(action.function)
		:erlang.apply(module, :call, [function, env, action.args])
	end
end
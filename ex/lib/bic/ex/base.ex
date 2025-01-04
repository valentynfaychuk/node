defmodule BIC.Base do
	import BIC.KV

	def init() do
		kv_create(:base)
		kv_create(:coin)
		kv_create(:trainers)
		kv_create(:solutions)
		kv_create(:tx_delayed)
		kv_create(:tx_result)
	end

	def exec_cost(tx_bytes) do
		BIC.Coin.to_cents( 1 + (trunc(tx_bytes/256)*3) )
	end

	def can_pay_exec_cost(env) do
		tx_bytes = byte_size(env.txu.tx_encoded)
		BIC.Coin.balance(env.txu.tx.signer) < exec_cost(tx_bytes)
	end

	def epoch(env) do
		trunc(env.block.height/100_000)
	end

	def precall_block(env) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)

        #thank you come again
		kv_increment(:coin, env.block.trainer, BIC.Coin.to_flat(1))

        cond do
        	env.block.height == 0 -> kv_merge(:trainers, env.block.trainer)
        	rem(env.block.height, 100_000) == 0 -> BIC.Trainer.epoch_init(env)
        	true -> :ok
        end
        precall_block_delayed(env)

        {Process.get(:mutations, <<>>), Process.get(:mutations_reverse, [])}
	end

	def precall_block_delayed(env) do
        case :ets.first_lookup(:tx_delayed) do
        	:'$end_of_table' -> :done
        	{_, [{{proc_height, hash}, txu}]} when proc_height == env.height -> 
        		process_tx_delayed(%{block: env.block, txu: txu})
        		kv_delete(:tx_delayed, {proc_height, hash})
        		precall_block_delayed(env)
        	{_, [{_, _}]} -> :done
        end
	end

	defp process_tx_delayed(env) do
		try do
			process_tx_2(env)
			kv_merge(:tx_result, env.txu.hash, %{error: :ok})
		catch
			:throw,r -> kv_merge(:tx_result, env.txu.hash, r)
			e,r ->
				IO.inspect {:tx_error_delayed, e, r, __STACKTRACE__}
				kv_merge(:tx_result, env.txu.hash, %{error: :unknown})
		end
	end

	def process_tx(env) do
        Process.delete(:mutations)
        Process.delete(:mutations_reverse)
		try do
			if kv_exists(:tx_result, env.txu.hash), do: throw %{error: :tx_replay}
			if :ets.match_object(:tx_delayed, {:_, env.txu.hash}) != [], do: throw %{error: :tx_replay}
			process_tx_1(env)
			kv_merge(:tx_result, env.txu.hash, %{error: :ok})
		catch
			:throw,%{error: :CATCH_tx_delayed} -> :ok
			:throw,r -> kv_merge(:tx_result, env.txu.hash, r)
			e,r ->
				IO.inspect {:tx_error, e, r, __STACKTRACE__}
				kv_merge(:tx_result, env.txu.hash, %{error: :unknown})
		end
        {Process.get(:mutations, <<>>), Process.get(:mutations_reverse, [])}
	end

	defp process_tx_1(env) do
		tx = env.txu.tx
		#tx_bytes = byte_size(env.tx_encoded)
		#if tx_bytes >= 1024, do: throw %{error: :tx_too_large}

		#if env.height > (tx.height+100_000), do: throw %{error: :stale_tx_height}
		
		#epoch = trunc(tx.height / 100_000)
		#block_epoch = trunc(env.height / 100_000)
		#if epoch != block_epoch, do: throw %{error: :stale_tx_height}

		exec_cost = exec_cost(byte_size(env.txu.tx_encoded))
		signerHasCoins = BIC.Coin.balance(tx.signer) >= exec_cost
		trainerHasCoins = BIC.Coin.balance(env.block.trainer) >= exec_cost
		cond do
			signerHasCoins -> 
				kv_increment(:coin, tx.signer, -exec_cost)
				kv_increment(:coin, BIC.Coin.burn_address(), exec_cost)
			trainerHasCoins ->
				kv_increment(:coin, env.block.trainer, -exec_cost)
				kv_increment(:coin, BIC.Coin.burn_address(), exec_cost)
			true ->
				kv_delete(:trainers, env.block.trainer)
				kv_delete_match(:solutions, {:_, %{trainer: env.block.trainer}})
		end

		if !!tx[:delay] and tx.delay <= 0, do: %{error: :delay_too_short}
		if !!tx[:delay] and tx.delay > 10_000, do: %{error: :delay_too_long}
		if !!tx[:delay] do
			kv_merge(:tx_delayed, {env.block.height+tx.delay, env.txu.hash}, env.txu)
			throw %{error: :CATCH_tx_delayed}
		else
			process_tx_2(env)
		end
	end

	defp process_tx_2(env) do
		<<seed::256-little>> = Blake3.hash(<<env.txu.hash_raw::binary, Base58.decode(env.block.vrf_signature)::binary>>)
	    :rand.seed(:exsss, seed)
		module = String.to_existing_atom("Elixir.BIC.#{env.txu.tx.action.contract}")
		function = String.to_existing_atom(env.txu.tx.action.function)
		:erlang.apply(module, :call, [function, env, env.txu.tx.action.args])
	end
end
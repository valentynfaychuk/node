defmodule BIC.Epoch do
    import ConsensusKV

	@epoch_emission_base BIC.Coin.to_flat(1_000_000)
	@epoch_interval 100_000

	def epoch_emission(_epoch, acc \\ @epoch_emission_base)
	def epoch_emission(0, acc) do acc end
	def epoch_emission(epoch, acc) do
		sub = div(acc * 666, 1000000)
		epoch_emission(epoch - 1, acc - sub)
	end

	def call(:submit_sol, env, [sol]) do
		if byte_size(sol) != 256, do: throw(%{error: :invalid_sol_seed_size})
		if kv_exists("bic:epoch:solutions:#{sol}"), do: throw(%{error: :sol_exists})
		
		<<epoch::32-little, pk::48-binary, pop::96-binary, _computor::48-binary, _::binary>> = sol
		if epoch != Entry.epoch(env.entry), do: throw(%{error: :invalid_epoch})
		if !validate_sol(sol), do: throw(%{error: :invalid_sol})

		if !kv_get("bic:epoch:pop:#{pk}") do
			if !BlsEx.verify?(pk, pop, pk, BLS12AggSig.dst_pop()), do: throw %{error: :invalid_pop}
			kv_put("bic:epoch:pop:#{pk}", pop)
		end
		kv_put("bic:epoch:solutions:#{sol}", pk)
	end

	def call(:set_emission_address, env, [address]) do
		if byte_size(address) != 48, do: throw(%{error: :invalid_address_pk})
		kv_put("bic:epoch:emission_address:#{env.txu.tx.signer}", address)
	end

	def validate_sol(sol) do
		#TODO: perhaps add slashing for DOSing invalid sols
		#if a != 0 or b != 0 or c != 0, do: throw(%{error: :invalid_sol})
		<<a,b,c,_::29-binary>> = UPOW.calculate(sol)
		a == 0
	end

	def next(env) do
		epoch = Entry.epoch(env.entry)

		leaders = kv_get_prefix("bic:epoch:solutions:")
		|> Enum.reduce(%{}, fn({_sol, pk}, acc)->
			Map.put(acc, pk, Map.get(acc, pk, 0) + 1)
		end)
		|> Enum.sort_by(& elem(&1,1), :desc)
		
		trainers = kv_get("bic:epoch:trainers:#{epoch}")
		trainers_to_recv_emissions = leaders
		|> Enum.filter(& elem(&1,0) in trainers)
		|> Enum.take(9)

		total_sols = Enum.reduce(trainers_to_recv_emissions, 0, & &2 + elem(&1,1))
		Enum.each(trainers_to_recv_emissions, fn({trainer, trainer_sols})->
			coins = div(trainer_sols * epoch_emission(epoch), total_sols)

			emission_address = kv_get("bic:epoch:emission_address:#{trainer}")
			if emission_address do
				kv_increment("bic:coin:balance:#{emission_address}", coins)
			else
				kv_increment("bic:coin:balance:#{trainer}", coins)
			end
		end)

		kv_clear("bic:epoch:solutions:")

		new_trainers = if length(leaders) == 0 do trainers else
			leaders = leaders
			|> Enum.take(9)
			|> Enum.shuffle()
			|> Enum.map(fn{pk, _}-> pk end)
		end
		kv_put("bic:epoch:trainers:#{epoch+1}", Enum.shuffle(new_trainers))
	end

	@doc """
	def call(:slash_double_entry, env, [entrya, entryb]) do
		%{trainer: trainera, height: heighta, hash: hasha} = entrychain.validate_entry(entrya)
		%{trainer: trainerb, height: heightb, hash: hashb} = entrychain.validate_entry(entryb)

		if trainera != trainerb, do: throw(%{error: :different_signer})
		if heighta != heightb, do: throw(%{error: :different_height})
		if trunc(heighta/100_000) != trunc(env.height/100_000), do: throw(%{error: :stale_chain_epoch})
		if hasha == hashb, do: throw(%{error: :same_entry})

		kv_delete(:trainers, trainera)
		kv_delete_match(:solutions, {:_, %{trainer: trainera}})
	end
	"""
end
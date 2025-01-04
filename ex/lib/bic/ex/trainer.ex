defmodule BIC.Trainer do
    import BIC.KV

	@epoch_emission BIC.Coin.to_flat(1_000_000)
	@epoch_interval 100_000
	@adjudicator "4MXG4qor6TRTX9Wuu9TEku7ivBtDooNL55vtu3HcvoQH"

	def slot(proof_of_history) do
		<<hash::256-little>> = proof_of_history
		trainers = kv_keys(:trainers)
		index = rem(hash, length(trainers))
		Enum.at(trainers, index)
	end

	def call(:submit_sol, env, [sol]) do
		sol_raw = Base58.decode(sol)
		if byte_size(sol_raw) != 160, do: throw(%{error: :invalid_sol_seed_size})
		if kv_get(:solutions, sol), do: throw(%{error: :sol_exists})
		
		<<trainer_raw::32-binary, _computor_raw::32-binary, epoch::32-little, _::binary>> = sol_raw
		if epoch != trunc(env.block.height/100_000), do: throw(%{error: :invalid_epoch})

		if !validate_sol(sol_raw), do: throw(%{error: :invalid_sol})

		kv_merge(:solutions, sol, %{trainer: Base58.encode(trainer_raw)})
	end

	def validate_sol(sol_raw) do
		#TODO: perhaps add slashing for DOSing invalid sols
		#if a != 0 or b != 0 or c != 0, do: throw(%{error: :invalid_sol})
		<<a,b,c,_::29-binary>> = UPOW.calculate(sol_raw)
		a == 0
	end

	def epoch_init(env) do
		leaders = kv_get(:solutions)
		|> Enum.reduce(%{}, fn(%{trainer: trainer}, acc)->
			Map.put(acc, trainer, Map.get(acc, trainer, 0) + 1)
		end)
		|> Enum.sort_by(& elem(&1,1), :desc)
		
		trainers_to_recv_emissions = leaders
		|> Enum.filter(& kv_get(:trainers, elem(&1,0)))
		|> Enum.take(10) #should be guaranteed but just incase

		total_sols = Enum.reduce(trainers_to_recv_emissions, 0, & &2 + elem(&1,1))
		Enum.each(trainers_to_recv_emissions, fn({trainer, trainer_sols})->
			coins = trunc((trainer_sols / total_sols) * @epoch_emission)
			kv_increment(:coin, trainer, coins)
		end)

		kv_clear(:trainers)
		kv_clear(:solutions)

		leaders
		|> Enum.take(9)
		|> Enum.map(fn{pubkey, _}-> pubkey end)
		|> Enum.each(fn(pubkey)->
			kv_merge(:trainers, pubkey)
		end)
		if BIC.Base.epoch(env) < 666 do
			kv_merge(:trainers, @adjudicator)
		end
	end

	def call(:slash_double_block, env, [blocka, blockb]) do
		%{trainer: trainera, height: heighta, hash: hasha} = Blockchain.validate_block(blocka)
		%{trainer: trainerb, height: heightb, hash: hashb} = Blockchain.validate_block(blockb)

		if trainera != trainerb, do: throw(%{error: :different_signer})
		if heighta != heightb, do: throw(%{error: :different_height})
		if trunc(heighta/100_000) != trunc(env.height/100_000), do: throw(%{error: :stale_chain_epoch})
		if hasha == hashb, do: throw(%{error: :same_block})

		kv_delete(:trainers, trainera)
		kv_delete_match(:solutions, {:_, %{trainer: trainera}})
	end
end
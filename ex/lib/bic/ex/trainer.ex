defmodule Contract.Trainer do
	#defmodule call(env, caller, func, args) do
	#end

	@adjudicator ""
	@epoch_emission 1_000_000

	def init() do
		create_kv(__MODULE__, __MODULE__)
    create_kv(__MODULE__, "solutions")
    create_kv(__MODULE__, "solutions_valid")
    create_kv(__MODULE__, "solutions_leaderboard")
	  create_kv(__MODULE__, "trainers")
	end

	def call(env, "submit_sol", [trainer_pubkey, epoch, nonce]) do
		if byte_size(trainer_pubkey) != 32, do: throw(%{error: :invalid_trainer_pubkey_size})
		if byte_size(nonce) != 32, do: throw(%{error: :invalid_nonce_size})
		epoch_cur = kv_get(__MODULE__, "epoch")
		if epoch != epoch_cur, do: throw(%{error: :invalid_epoch})
		if kv_get("solutions", {trainer_pubkey, epoch, nonce}), do: throw(%{error: :sol_exists})

		kv_merge("solutions", {trainer_pubkey, epoch, nonce})
		%{error: :ok}
	end

	def call(env, "validate_sol", [trainer_pubkey, epoch, nonce]) do
		if !kv_get("trainers", env.caller), do: throw(%{error: :caller_not_trainer})
		epoch_cur = kv_get(__MODULE__, "epoch")
		if epoch != epoch_cur, do: throw(%{error: :invalid_epoch})

		kv_delete("solutions", {trainer_pubkey, epoch, nonce})
		kv_merge("solutions_valid", {trainer_pubkey, epoch, nonce})
		kv_increment("solutions_leaderboard", {trainer_pubkey, epoch}, 1)
		%{error: :ok, total_sols: kv_get("solutions_leaderboard", {trainer_pubkey, epoch})}
	end

	def call(env, "epoch_next", []) do
		if !kv_get("trainers", env.caller), do: throw(%{error: :caller_not_trainer})

		epoch_cur = kv_get(__MODULE__, "epoch")

		leaders = :ets.tab2list(env.tables[:solutions_valid])
		|> Enum.filter(fn{{_,epoch,_},_}-> epoch == epoch_cur end)
		|> Enum.sort_by(& &2, :desc)
		|> Enum.take(9)

		total_sols = Enum.map(fn{{_,_,_},sols}-> sols end)
		|> Enum.sum()
		leaders_ratios = Enum.each(leaders, fn({{pubkey,_,_},sols})->
			coins = trunc(sols / total_sols * @epoch_emission)
			Contract.Coin.mint(pubkey, Contract.Coin.to_flat(coins))
		end)

		leaders_pubkeys = leaders
		|> Enum.map(fn{{pubkey,_,_},_}-> pubkey end)

		kv_clear(env.tables[:trainers])
		Enum.each(leaders_pubkeys, fn(pubkey)->
			kv_merge(env, :trainers, pubkey)
		end)
		kv_merge(env, :trainers, @adjudicator)

		kv_increment(__MODULE__, "epoch")

		%{error: :ok, trainers: leaders_pubkeys}
	end

	def is_trainer(env, pubkey) do
		!!kv_get(env, __MODULE__, "trainers", pubkey)
	end
end

defmodule BIC.Coin do
	@decimals 9
	def to_flat(coins) do
		if !is_integer(coin), do: throw(:coins_not_integer)
		trunc(coins * 1_000_000_000)
	end

	def balance() do
	end

	def mint(env, pubkey, amount) do
		if !BIC.Trainer.is_trainer(pubkey), do: throw(%{error: :caller_not_trainer})
		kv_increment(env, __MODULE__, "balance", pubkey, amount)
	end

	def nonce(env, pubkey) do
		kv_get(env, __MODULE__, "nonce", pubkey) || 0
	end
end

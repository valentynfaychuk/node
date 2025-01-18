defmodule BIC.Coin do
	import ConsensusKV

	@decimals 9
	@burn_address Base58.encode(:binary.copy(<<0>>, 48))

	def to_flat(coins) when is_integer(coins) do
		coins * 1_000_000_000
	end

	def to_cents(coins) when is_integer(coins) do
		coins *    10_000_000
	end

	def from_flat(coins) do
		Float.round(coins / 1_000_000_000, 9)
	end

	def burn_address() do
		@burn_address
	end

	def balance(pubkey) do
		kv_get("bic:coin:balance:#{pubkey}") || 0
	end

	def call(:transfer, env, [receiver, amount]) do
		receiver = Base58.decode(receiver)
		if byte_size(receiver) != 48, do: throw(%{error: :invalid_receiver_pk})
		amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end
		if !is_integer(amount), do: throw(%{error: :invalid_amount})
		if amount <= 0, do: throw(%{error: :invalid_amount})
		if amount > balance(env.txu.tx.signer), do: throw(%{error: :insufficient_funds})

		kv_increment("bic:coin:balance:#{env.txu.tx.signer}", -amount)
		kv_increment("bic:coin:balance:#{receiver}", amount)
	end
end

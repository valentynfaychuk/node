defmodule BIC.Coin do
	import BIC.KV

	@decimals 9
	@burn_address Base58.encode(:binary.copy(<<0>>, 32))

	def to_flat(coins) do
		trunc(coins * 1_000_000_000)
	end

	def to_cents(coins) do
		trunc(coins *    10_000_000)
	end

	def from_flat(coins) do
		Float.round(coins / 1_000_000_000, 9)
	end

	def burn_address() do
		@burn_address
	end

	def balance(pubkey) do
		kv_get(:coin, pubkey) || 0
	end

	def call(:transfer, env, [receiver, amount]) do
		if byte_size(Base58.decode(receiver)) != 32, do: throw(%{error: :invalid_receiver_pk})
		amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end
		if !is_integer(amount), do: throw(%{error: :invalid_amount})
		if amount <= 0, do: throw(%{error: :invalid_amount})
		if amount > balance(env.txu.tx.signer), do: throw(%{error: :insufficient_funds})

		kv_increment(:coin, env.txu.tx.signer, -amount)
		kv_increment(:coin, receiver, amount)
	end
end

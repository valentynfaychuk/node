defmodule BIC.Base do
	def init() do
		create_kv(__MODULE__, "nonce")
	end

	def process_tx(tx) do
		BIC.coin.balance() > 1
		kv_increment(__MODULE__, "nonce", 1)
		BIC.coin.mint(BIC.Coin.to_flat(-1))
	end
end

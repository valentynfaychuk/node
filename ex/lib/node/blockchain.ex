defmodule Blockchain do
	@epoch_blocks 100_000

	def create_block(trainer_sk, hash) do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519, trainer_sk)

		lb = FlatKV.get(Blockchain, hash)

		new_height = lb.height + 1
		old_epoch = trunc(lb.height / 100_000)
		new_epoch = trunc(new_height / 100_000)

		txs = []

		txs = txs ++ [TX.build_transaction(sk, -1, "Coin", "mint", [pk |> Base58.encode, Contract.Coin.to_flat(100)], 0)]
		txs = if new_epoch == old_epoch do txs else
			txs ++ [TX.build_transaction(sk, -1, "Trainer", "epoch_next", [], 0)]
		end

		block = %{
			height: new_height,
			prev_height: lb.height,
			prev_hash: lb.hash,
			proof_of_history: Blake3.hash(lb.proof_of_history |> Base58.decode()) |> Base58.encode(),
			vrf_signature: :public_key.sign(lb.vrf_signature |> Base58.decode(), :ignored, {:ed_pri, :ed25519, pk, sk}, []) |> Base58.encode(),
			epoch: new_epoch,
			state_root: Blake3.hash("aaa") |> Base58.encode(),
			transactions: [],
			trainer: pk,
		}

		block_encoded = block
		|> Enum.sort_by(& &1)
		|> JSX.encode!()
		block_hash = Blake3.hash(block_encoded)
		signature = :public_key.sign(block_hash, :ignored, {:ed_pri, :ed25519, pk, sk}, [])
		header = %{
			block: block_encoded,
			hash: block_hash |> Base58.encode(),
			signature: signature |> Base58.encode()
		}
	end

	def validate_block() do
	end

	def test() do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
		signed_tx = Blockchain.build_transaction(sk, 0, "Trainer", "submit_sol", [123])
		Blockchain.validate_transaction(signed_tx)
	end
end

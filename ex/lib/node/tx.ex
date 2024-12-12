defmodule TX do
	def build_transaction(secretkey, nonce, contract, function, args, gas \\ 1) do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519, secretkey)
		tx = %{
			sender: Base58.encode(pk),
			nonce: nonce,
			gas: Contract.Coin.to_flat(gas),
			contract: contract,
			function: function,
			args: args,
		}
		|> Enum.sort_by(& &1)
		|> JSX.encode!()
		signature = :public_key.sign(tx, :ignored, {:ed_pri, :ed25519, pk, sk}, [])
		|> Base58.encode()
		<<signature::binary, ".", tx::binary>>
	end

	def validate_transaction(signed_tx) do
		try do
		if byte_size(signed_tx) > 1024, do: throw(%{error: :too_large})
		[signature, tx_json] = :binary.split(signed_tx, ".")
		tx = JSX.decode!(tx_json, labels: :attempt_atom)
		if !:public_key.verify(tx_json, :ignored, Base58.decode(signature), {:ed_pub, :ed25519, Base58.decode(tx.sender)}), do: throw(%{error: :invalid_signature})
		if !is_integer(tx.nonce), do: throw(%{error: :nonce_not_integer})
		if !is_integer(tx.gas), do: throw(%{error: :gas_not_integer})
		if tx.contract not in ["Trainer", "Coin"], do: throw(%{error: :invalid_contract})
		if tx.function not in ["send", "submit_sol", "validate_sol"], do: throw(%{error: :invalid_function})
		if !is_list(tx.args), do: throw(%{error: :args_must_be_list})
		Enum.each(tx.args, fn(arg)->
			if !is_integer(arg) and !is_binary(arg), do: throw(%{error: :arg_invalid_type})
		end)

		proplist = :jsx.decode(tx_json, labels: :attempt_atom, return_maps: false)
		sorted = Enum.sort_by(proplist, & &1)
		if proplist != sorted, do: throw(%{error: :json_not_canonical})

		throw(%{error: :ok})
		catch
			:throw,r -> r
			e,r ->
			  IO.inspect {Blockchain, :validate_transaction, e, r}
				%{error: :unknown}
		end
	end

	def test() do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
		signed_tx = Blockchain.build_transaction(sk, 0, "Trainer", "submit_sol", [123])
		Blockchain.validate_transaction(signed_tx)
	end
end

defmodule TX do
	def build_transaction(secretkey, height, contract, function, args) do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519, secretkey)
		action = %{op: "call", contract: contract, function: function, args: args}
		#action = if !is_list(attach) do action else
		#	Map.put(action, :attach, attach)
		#end
		tx_encoded = %{
			signer: Base58.encode(pk),
			nonce: :rand.uniform(4_294_967_295), #:rand.uniform(18_446_744_073_709_551_616)
			height: height,
			action: action
		}
		|> JCS.serialize()
		hash = Blake3.hash(tx_encoded)
		signature = :public_key.sign(hash, :ignored, {:ed_pri, :ed25519, pk, sk}, [])
		
		<<Base58.encode(hash)::binary,".",Base58.encode(signature)::binary,".",tx_encoded::binary>>
	end

	def validate(tx_packed) do
		try do
        tx_size = Application.fetch_env!(:ama, :tx_size)
		if byte_size(tx_packed) > tx_size, do: throw(%{error: :too_large})
		
		txp = unwrap(tx_packed)
		if !JCS.validate(txp.tx_encoded), do: throw(%{error: :json_not_canonical})

		hash = txp.hash |> Base58.decode
		signature = txp.signature |> Base58.decode

		if hash != Blake3.hash(txp.tx_encoded), do: throw(%{error: :invalid_hash})
		if !:public_key.verify(hash, :ignored, signature, {:ed_pub, :ed25519, Base58.decode(txp.tx.signer)}), do: throw(%{error: :invalid_signature})
		if !is_integer(txp.tx.nonce), do: throw(%{error: :nonce_not_integer})
		if !is_integer(txp.tx.height), do: throw(%{error: :height_not_integer})
		if !is_map(txp.tx.action), do: throw(%{error: :action_must_be_map})
		if txp.tx.action[:op] != "call", do: throw %{error: :op_must_be_call}
		if !is_binary(txp.tx.action[:contract]), do: throw %{error: :contract_must_be_binary}
		if !is_binary(txp.tx.action[:function]), do: throw %{error: :function_must_be_binary}
		if !is_list(txp.tx.action[:args]), do: throw %{error: :args_must_be_list}
		Enum.each(txp.tx.action.args, fn(arg)->
			if !is_integer(arg) and !is_binary(arg), do: throw(%{error: :arg_invalid_type})
		end)
		if !:lists.member(txp.tx.action.contract, ["Trainer", "Coin"]), do: throw %{error: :invalid_module}
		if !:lists.member(txp.tx.action.function, ["submit_sol", "kick_double_block", "transfer"]), do: throw %{error: :invalid_function}

		if !!txp.tx[:delay] and !is_integer(txp.tx.delay), do: throw %{error: :delay_not_integer}
		if !!txp.tx[:delay] and txp.tx.delay <= 0, do: throw %{error: :delay_too_low}
		if !!txp.tx[:delay] and txp.tx.delay > 100_000, do: throw %{error: :delay_too_hi}

		throw(%{error: :ok})
		catch
			:throw,r -> r
			e,r ->
			    IO.inspect {TX, :validate, e, r}
				%{error: :unknown}
		end
	end

    def unwrap(tx_packed) do
        [hash, tx_packed] = :binary.split(tx_packed, ".")
        [signature, tx_encoded] = :binary.split(tx_packed, ".")
        tx = JSX.decode!(tx_encoded, labels: :attempt_atom)
        %{tx: tx, tx_encoded: tx_encoded,
        	signature: signature, signature_raw: Base58.decode(signature),
        	hash: hash, hash_raw: Base58.decode(hash)}
    end

    def wrap(txu) do
        <<txu.hash::binary,".",txu.signature::binary,".",txu.tx_encoded::binary>>
    end

	def test() do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
		packed_tx = TX.build_transaction(sk, 0, "Trainer", "submit_sol", [<<>>])
		TX.validate(packed_tx)
	end
end

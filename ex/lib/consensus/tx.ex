defmodule TX do
	@doc """
	%{
		signer: Base58PK,
		nonce: :os.system_time(:nanosecond),
		height: height,
		actions: [%{op: "call", contract: "", function: "", args: []}]
	}
	"""

	def validate(tx_packed) do
		try do
        [hash, tx_packed] = :binary.split(tx_packed, ".")
        [signature, tx_encoded] = :binary.split(tx_packed, ".")

       	tx_size = Application.fetch_env!(:ama, :tx_size)
	    if byte_size(tx_packed) >= tx_size, do: throw(%{error: :too_large})

        tx = JCS.validate(tx_encoded)
		if !tx, do: throw(%{error: :json_not_canonical})

		hash_raw = Base58.decode(hash)
		signature_raw = Base58.decode(signature)
    	if hash_raw != Blake3.hash(tx_encoded), do: throw(%{error: :invalid_hash})
    	if !BlsEx.verify_signature?(Base58.decode(tx.signer), hash_raw, signature_raw), do: throw(%{error: :invalid_signature})

		if !is_integer(tx.nonce), do: throw(%{error: :nonce_not_integer})
		if !is_integer(tx.height), do: throw(%{error: :height_not_integer})
		if !is_list(tx.actions), do: throw(%{error: :actions_must_be_list})
		if length(tx.actions) != 1, do: throw(%{error: :actions_length_must_be_1})
		action = hd(tx.actions)
		if action[:op] != "call", do: throw %{error: :op_must_be_call}
		if !is_binary(action[:contract]), do: throw %{error: :contract_must_be_binary}
		if !is_binary(action[:function]), do: throw %{error: :function_must_be_binary}
		if !is_list(action[:args]), do: throw %{error: :args_must_be_list}
		Enum.each(action.args, fn(arg)->
			if !is_integer(arg) and !is_binary(arg), do: throw(%{error: :arg_invalid_type})
		end)
		if !:lists.member(action.contract, ["Epoch", "Coin"]), do: throw %{error: :invalid_module}
		if !:lists.member(action.function, ["submit_sol", "transfer", "set_emission_address"]), do: throw %{error: :invalid_function}

		#if !!txp.tx[:delay] and !is_integer(txp.tx.delay), do: throw %{error: :delay_not_integer}
		#if !!txp.tx[:delay] and txp.tx.delay <= 0, do: throw %{error: :delay_too_low}
		#if !!txp.tx[:delay] and txp.tx.delay > 100_000, do: throw %{error: :delay_too_hi}

        tx = Map.put(tx, :signer, Base58.decode(tx.signer))
		throw %{error: :ok, txu: %{tx: tx, tx_encoded: tx_encoded,
        	signature: signature, signature_raw: signature_raw,
        	hash: hash, hash_raw: hash_raw}}
		catch
			:throw,r -> r
			e,r ->
			    IO.inspect {TX, :validate, e, r}
				%{error: :unknown}
		end
	end

	def build_transaction(sk_raw, height, contract, function, args) do
		pk_raw = BlsEx.get_public_key!(sk_raw)
		action = %{op: "call", contract: contract, function: function, args: args}
		tx_encoded = %{
			signer: Base58.encode(pk_raw),
			nonce: :os.system_time(:nanosecond),
			height: height,
			actions: [action]
		}
		|> JCS.serialize()
		hash = Blake3.hash(tx_encoded)
        signature = BlsEx.sign!(sk_raw, hash)

		<<Base58.encode(hash)::binary,".",Base58.encode(signature)::binary,".",tx_encoded::binary>>
	end

	def chain_valid(tx_packed) do
		txu = unwrap(tx_packed)

        #TODO: once more than 1 tx allowed per entry fix this
		chainNonce = Consensus.chain_nonce(txu.tx.signer)
        nonceValid = !chainNonce or txu.tx.nonce > chainNonce
        hasBalance = BIC.Base.exec_cost(tx_packed) <= Consensus.chain_balance(txu.tx.signer)
        cond do
           !nonceValid -> false
           !hasBalance -> false
           true -> true
        end
	end

    def wrap(txu) do
        <<txu.hash::binary,".",txu.signature::binary,".",txu.tx_encoded::binary>>
    end

    def unwrap(tx_packed, verify \\ false) do
        [hash, tx_packed] = :binary.split(tx_packed, ".")
        [signature, tx_encoded] = :binary.split(tx_packed, ".")
        tx = JSX.decode!(tx_encoded, labels: :attempt_atom)
        tx = Map.put(tx, :signer, Base58.decode(tx.signer))
        %{tx: tx, tx_encoded: tx_encoded,
        	signature: signature, signature_raw: Base58.decode(signature),
        	hash: hash, hash_raw: Base58.decode(hash)}
    end

	def test() do
	end
end

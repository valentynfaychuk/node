defmodule TX do
   _ = """
   %{
     tx: %{
      signer: Base58PK,
      nonce: :os.system_time(:nanosecond),
      actions: [%{op: "call", contract: "", function: "", args: []}]
     },
     tx_encoded: <<>>,
     hash: <<>>,
     signature: <<>>
   }
   tx = TX.build(Application.fetch_env!(:ama, :trainer_sk), "Coin", "transfer", [])
   {tx1,_} = VanillaSer.decode(tx)
   tx2 = RDB.vecpak_decode(tx)
   VanillaSer.decode(tx1["tx_encoded"])
   VanillaSer.decode(tx2.tx_encoded)
   RDB.vecpak_decode(tx1["tx_encoded"])
   RDB.vecpak_decode(tx2.tx_encoded)

   VanillaSer.encode(VanillaSer.decode(tx1["tx_encoded"]) |> elem(0)) |> RDB.vecpak_decode()
   RDB.vecpak_encode(tx2.tx_encoded) |> RDB.vecpak_decode()

   <<5, 1, 2, 111, 112>>
   <<5, 1, 4, 97, 114, 103, 115>>
   <<5, 1, 8, 99, 111, 110, 116, 114, 97, 99, 116>>
   <<5, 1, 8, 102, 117, 110, 99, 116, 105, 111, 110>>
   <<5, 1, 5, 110, 111, 110, 99, 101>>
   <<5, 1, 6, 115, 105, 103, 110, 101, 114>>
   <<5, 1, 7, 97, 99, 116, 105, 111, 110, 115>>

   """

   @fields [:tx_encoded, :hash, :signature] #,    :tx
   @fields_tx [:actions, :signer, :nonce, :action]
   @fields_action [:op, :contract, :function, :args, :attached_symbol, :attached_amount]

   def pack(txu, height \\ nil) do
     height = if height do height else DB.Chain.height() end
     if height >= Entry.forkheight() do
      txu = Map.take(txu, @fields)
      RDB.vecpak_encode(txu)
     else
      txu = Map.take(txu, @fields)
      VanillaSer.encode(txu)
     end
   end

   def unpack(tx_packed) do
     try do
     txu = VanillaSer.decode!(tx_packed)
     tx = VanillaSer.decode!(Map.fetch!(txu, :tx_encoded))
     txu = Map.put(txu, :tx, tx)
     catch
     _,_ ->
      txu = RDB.vecpak_decode(tx_packed)
      tx = RDB.vecpak_decode(Map.fetch!(txu, :tx_encoded))
      txu = Map.put(txu, :tx, tx)
     end
   end

   def validate(txu, is_special_meeting_block \\ false) do
    height = Process.get(:height_for_tx, DB.Chain.height())
    if height >= Entry.forkheight() do
      try do
      tx_packed = TX.pack(txu, height)
      tx_size = Application.fetch_env!(:ama, :tx_size)
      if byte_size(tx_packed) >= tx_size, do: throw(%{error: :too_large})

      txu = RDB.vecpak_decode(tx_packed)
      txu = Map.take(txu, @fields)
      tx_encoded = Map.fetch!(txu, :tx_encoded)
      tx = RDB.vecpak_decode(tx_encoded)
      tx = Map.take(tx, @fields_tx)
      tx = put_in(tx, [:action], Map.take(tx.action, @fields_action))
      txu = Map.put(txu, :tx, tx)
      hash = Map.fetch!(txu, :hash)
      signature = Map.fetch!(txu, :signature)

      if hash != :crypto.hash(:sha256, tx_encoded), do: throw(%{error: :invalid_hash})
      if !BlsEx.verify?(txu.tx.signer, signature, hash, BLS12AggSig.dst_tx()), do: throw(%{error: :invalid_signature})

      if !is_integer(txu.tx.nonce), do: throw(%{error: :nonce_not_integer})
      if txu.tx.nonce > 99_999_999_999_999_999_999, do: throw(%{error: :nonce_too_high})

      if !is_map(txu.tx.action), do: throw(%{error: :action_must_be_map})
      action = txu.tx.action
      if action[:op] != "call", do: throw %{error: :op_must_be_call}
      if !is_binary(action[:contract]), do: throw %{error: :contract_must_be_binary}
      if !is_binary(action[:function]), do: throw %{error: :function_must_be_binary}
      if !is_list(action[:args]), do: throw %{error: :args_must_be_list}
      Enum.each(action.args, fn(arg)->
        if !is_binary(arg), do: throw(%{error: :arg_must_be_binary})
      end)

      if is_special_meeting_block do
         if !:lists.member(action.contract, ["Epoch"]), do: throw %{error: :invalid_module_for_special_meeting}
         if !:lists.member(action.function, ["slash_trainer"]), do: throw %{error: :invalid_function_for_special_meeting}
      end

      #attachment
      if !!action[:attached_symbol] and !is_binary(action.attached_symbol), do: throw %{error: :attached_symbol_must_be_binary}
      if !!action[:attached_symbol] and (byte_size(action.attached_symbol) < 1 or byte_size(action.attached_symbol) > 32),
        do: throw %{error: :attached_symbol_wrong_size}

      if !!action[:attached_amount] and !is_binary(action.attached_amount), do: throw %{error: :attached_amount_must_be_binary}

      if !!action[:attached_symbol] and !action[:attached_amount], do: throw %{error: :attached_amount_must_be_included}
      if !!action[:attached_amount] and !action[:attached_symbol], do: throw %{error: :attached_symbol_must_be_included}

      #if !!txp.tx[:delay] and !is_integer(txp.tx.delay), do: throw %{error: :delay_not_integer}
      #if !!txp.tx[:delay] and txp.tx.delay <= 0, do: throw %{error: :delay_too_low}
      #if !!txp.tx[:delay] and txp.tx.delay > 100_000, do: throw %{error: :delay_too_hi}

      throw %{error: :ok, txu: txu}
      catch
         :throw,r -> r
         e,r ->
             IO.inspect {TX, :validate, e, r}
            %{error: :unknown, txu: nil}
      end

    else
      try do
      tx_packed = TX.pack(txu)
      tx_size = Application.fetch_env!(:ama, :tx_size)
      if byte_size(tx_packed) >= tx_size, do: throw(%{error: :too_large})

      txu = VanillaSer.decode!(tx_packed)
      txu = Map.take(txu, @fields)
      tx_encoded = Map.fetch!(txu, :tx_encoded)
      tx = VanillaSer.decode!(tx_encoded)
      tx = Map.take(tx, @fields_tx)
      actions = Enum.map(Map.fetch!(tx, :actions), & Map.take(&1, @fields_action))
      tx = Map.put(tx, :actions, actions)
      txu = Map.put(txu, :tx, tx)
      hash = Map.fetch!(txu, :hash)
      signature = Map.fetch!(txu, :signature)

      canonical = VanillaSer.encode(%{tx_encoded: VanillaSer.encode(tx), hash: hash, signature: signature})
      if tx_packed != canonical, do: throw(%{error: :tx_not_canonical})

      if hash != Blake3.hash(tx_encoded), do: throw(%{error: :invalid_hash})
      if !BlsEx.verify?(txu.tx.signer, signature, hash, BLS12AggSig.dst_tx()), do: throw(%{error: :invalid_signature})

      if !is_integer(txu.tx.nonce), do: throw(%{error: :nonce_not_integer})
      if txu.tx.nonce > 99_999_999_999_999_999_999, do: throw(%{error: :nonce_too_high})
      if !is_list(txu.tx.actions), do: throw(%{error: :actions_must_be_list})
      if length(txu.tx.actions) != 1, do: throw(%{error: :actions_length_must_be_1})
      action = hd(txu.tx.actions)
      if action[:op] != "call", do: throw %{error: :op_must_be_call}
      if !is_binary(action[:contract]), do: throw %{error: :contract_must_be_binary}
      if !is_binary(action[:function]), do: throw %{error: :function_must_be_binary}
      if !is_list(action[:args]), do: throw %{error: :args_must_be_list}

      epoch = DB.Chain.epoch()
      Enum.each(action.args, fn(arg)->
        if !is_binary(arg), do: throw(%{error: :arg_must_be_binary})
      end)

      if is_special_meeting_block do
         if !:lists.member(action.contract, ["Epoch"]), do: throw %{error: :invalid_module_for_special_meeting}
         if !:lists.member(action.function, ["slash_trainer"]), do: throw %{error: :invalid_function_for_special_meeting}
      end

      #attachment
      if !!action[:attached_symbol] and !is_binary(action.attached_symbol), do: throw %{error: :attached_symbol_must_be_binary}
      if !!action[:attached_symbol] and (byte_size(action.attached_symbol) < 1 or byte_size(action.attached_symbol) > 32),
        do: throw %{error: :attached_symbol_wrong_size}

      if !!action[:attached_amount] and !is_binary(action.attached_amount), do: throw %{error: :attached_amount_must_be_binary}

      if !!action[:attached_symbol] and !action[:attached_amount], do: throw %{error: :attached_amount_must_be_included}
      if !!action[:attached_amount] and !action[:attached_symbol], do: throw %{error: :attached_symbol_must_be_included}

      #if !!txp.tx[:delay] and !is_integer(txp.tx.delay), do: throw %{error: :delay_not_integer}
      #if !!txp.tx[:delay] and txp.tx.delay <= 0, do: throw %{error: :delay_too_low}
      #if !!txp.tx[:delay] and txp.tx.delay > 100_000, do: throw %{error: :delay_too_hi}

      throw %{error: :ok, txu: txu}
      catch
         :throw,r -> r
         e,r ->
             IO.inspect {TX, :validate, e, r}
            %{error: :unknown, txu: nil}
      end
    end
   end

   def build(sk, contract, function, args, nonce \\ nil, attached_symbol \\ nil, attached_amount \\ nil) do
     height = DB.Chain.height()
     if height >= Entry.forkheight() do
       pk = BlsEx.get_public_key!(sk)
       nonce = if !nonce do :os.system_time(:nanosecond) else nonce end
       action = %{op: "call", contract: contract, function: function, args: args}
       action = if is_binary(attached_symbol) and is_binary(attached_amount) do
         Map.merge(action, %{attached_symbol: attached_symbol, attached_amount: attached_amount})
       else action end
       tx_encoded = %{
          signer: pk,
          nonce: nonce,
          action: action
       }
       |> RDB.vecpak_encode()
       hash = :crypto.hash(:sha256, tx_encoded)
       signature = BlsEx.sign!(sk, hash, BLS12AggSig.dst_tx())
       %{tx_encoded: tx_encoded, hash: hash, signature: signature}
      else
      pk = BlsEx.get_public_key!(sk)
      nonce = if !nonce do :os.system_time(:nanosecond) else nonce end
      action = %{op: "call", contract: contract, function: function, args: args}
      action = if is_binary(attached_symbol) and is_binary(attached_amount) do
        Map.merge(action, %{attached_symbol: attached_symbol, attached_amount: attached_amount})
      else action end
      tx_encoded = %{
         signer: pk,
         nonce: nonce,
         actions: [action]
      }
      |> VanillaSer.encode()
      hash = Blake3.hash(tx_encoded)
      signature = BlsEx.sign!(sk, hash, BLS12AggSig.dst_tx())
      %{tx_encoded: tx_encoded, hash: hash, signature: signature}
     end
   end

   def valid_pk(pk) do
      pk == BIC.Coin.burn_address() or BlsEx.validate_public_key(pk)
   end

   def known_receivers(txu) do
      action = action(txu)
      c = action.contract
      f = action.function
      a = action.args
      case {c,f,a} do
         {"Coin", "transfer", [receiver, _amount, _symbol]} -> valid_pk(receiver) && [receiver]
         {"Epoch", "slash_trainer", [_epoch, malicious_pk, _signature, _mask_size, _mask]} -> valid_pk(malicious_pk) && [malicious_pk]
         _ -> nil
      end || []
   end

   def exec_cost(epoch, txu) do
      if txu[:tx_encoded] do
        bytes = byte_size(txu.tx_encoded) + 32 + 96
        BIC.Coin.to_cents( 1 + div(bytes, 1024) * 1 )
      else
        bytes = byte_size(TX.pack(txu.tx)) + 32 + 96
        BIC.Coin.to_cents( 1 + div(bytes, 1024) * 1 )
      end
   end

   def action(%{tx: %{actions: [action|_]}}), do: action
   def action(%{tx: %{action: action}}), do: action
end

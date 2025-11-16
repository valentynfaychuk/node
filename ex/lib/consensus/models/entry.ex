defmodule Entry do
    _ = """
    entry %{
        header %{
            slot: 9,
            height: 6,
            prev_slot: 5,
            prev_hash: <<>>,
            signer: <>,
            dr <hash(prev_dr)>
            vr <sign(prev_vr)>
            txs_hash: <32>
        }
        txs []
        hash <header>
        sig <hash>
        optional|mask <bits>
    }

    entry %{
        header %{
            height: 6,
            prev_hash: <<>>,
            proposer: <>,
            dr <hash(prev_dr)>
            vr <sign(prev_vr)>
            tx_root: <32>   0 1 2 3 4 txs_count txs_hash
            validator_root: 0 1 2 3 4 validators_count validators_hash last_validators_change
            chain_root:     0 1 2 3 4 chain_id chain_tip chain_tip_height (leave out for a future update)
        }
        hash <header>
        aggsig { (mask_size always 1 if proposer is not 0) (if proposer is 0, it means proposer is down and VDF executed + network arrived at empty block)
          signature
          mask
          mask_size
          mask_set_size
        }
        txs []
    }
    h (header)

    consensus %{
      receipts_logs_extra_root: <32>,
      state_root: <32>, all_contract_state
      entry_hash: <32>,
      aggsig: %{
        mask: <<0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0>>,
        aggsig: <96>,
        mask_size: 99,
        mask_set_size: 1
      }
    }
    h (entry_hash || state_root || receipts_logs_extra_root)
    """

    @fields [:header, :hash, :signature, :txs, :mask, :mask_size, :mask_set_size]
    @fields_header [:height, :prev_hash, :slot, :prev_slot, :signer, :dr, :vr, :txs_hash]
    @forkheight 402_00000

    def forkheight() do
      @forkheight
    end

    def unpack_from_db(nil), do: nil
    def unpack_from_db(entry_packed) do
        entry = if is_binary(entry_packed) do RDB.vecpak_decode(entry_packed) else entry_packed end
        Map.take(entry, @fields)
    end

    def pack_for_db(entry_packed) when is_binary(entry_packed) do entry_packed end
    def pack_for_db(entry) do
        entry = Map.take(entry, @fields)
        entry_header = Map.take(entry.header, @fields_header)
        entry = Map.put(entry, :header, entry_header)
        RDB.vecpak_encode(entry)
    end

    def unpack_from_net(nil), do: nil
    def unpack_from_net(entry) do
        entry = Map.take(entry, @fields)
        entry_header = Map.take(entry.header, @fields_header)
        entry = Map.put(entry, :header, entry_header)
        if !entry[:mask] do entry else
          trainers = DB.Chain.validators_for_height(entry_header.height)
          trainers_signed = BLS12AggSig.unmask_trainers(trainers, entry.mask, entry.mask_size)
          true = entry.mask_size == length(trainers)
          true = entry.mask_set_size == length(trainers_signed)
          entry
        end
    end

    def pack_for_net(entry) do
      entry = Map.take(entry, @fields)
      entry_header = Map.take(entry.header, @fields_header)
      Map.put(entry, :header, entry_header)
    end

    def sign(sk, entry = %{header: %{height: height}}) when height >= @forkheight do
        txs_hash = :crypto.hash(:sha256, Enum.join(entry.txs))
        entry = put_in(entry, [:header, :txs_hash], txs_hash)
        hash = :crypto.hash(:sha256, RDB.vecpak_encode(entry.header))
        signature = BlsEx.sign!(sk, hash, BLS12AggSig.dst_entry())
        %{
            header: entry.header,
            hash: hash,
            signature: signature,
            txs: entry.txs,
        }
    end
    def sign(sk, entry) do
        txs_hash = Blake3.hash(Enum.join(entry.txs))
        entry = put_in(entry, [:header, :txs_hash], txs_hash)
        hash = Blake3.hash(:erlang.term_to_binary(entry.header, [:deterministic]))
        signature = BlsEx.sign!(sk, hash, BLS12AggSig.dst_entry())
        %{
            header: entry.header,
            hash: hash,
            signature: signature,
            txs: entry.txs,
        }
    end

    def unpack_and_validate_from_net(entry) do
        try do
        entry = unpack_from_net(entry)

        res_sig = validate_signature(entry)
        res_entry = validate_entry(entry)

        cond do
            res_sig.error != :ok -> throw res_sig
            res_entry.error != :ok -> throw res_entry
            true -> %{error: :ok, entry: entry}
        end
        catch
            :throw,r -> r
            e,r -> IO.inspect {Entry, :unpack_and_validate, e, r, __STACKTRACE__}; %{error: :unknown}
        end
    end

    def validate_entry(e) do
        try do
        eh = e.header
        if !is_integer(eh.slot), do: throw(%{error: :slot_not_integer})
        if !is_integer(eh.prev_slot), do: throw(%{error: :prev_slot_not_integer})
        if !is_integer(eh.height), do: throw(%{error: :height_not_integer})
        if !is_binary(eh.prev_hash), do: throw(%{error: :prev_hash_not_binary})
        if byte_size(eh.prev_hash) != 32, do: throw(%{error: :prev_hash_not_256_bits})
        if !is_binary(eh.dr), do: throw(%{error: :dr_not_binary})
        if byte_size(eh.dr) != 32, do: throw(%{error: :dr_not_256_bits})
        if !is_binary(eh.vr), do: throw(%{error: :vr_not_binary})
        if byte_size(eh.vr) != 96, do: throw(%{error: :vr_not_96_bytes})
        if !is_binary(eh.signer), do: throw(%{error: :signer_not_binary})
        if byte_size(eh.signer) != 48, do: throw(%{error: :signer_not_48_bytes})
        if !is_binary(eh.txs_hash), do: throw(%{error: :txs_hash_not_binary})
        if byte_size(eh.txs_hash) != 32, do: throw(%{error: :txs_hash_not_256_bits})

        if !!e[:mask] and !is_bitstring(e.mask), do: throw(%{error: :mask_not_bitstring})

        if !is_list(e.txs), do: throw(%{error: :txs_not_list})
        if length(e.txs) > 100, do: throw(%{error: :TEMPORARY_txs_only_100_per_entry})

        if eh.height >= @forkheight do
          if eh.txs_hash != :crypto.hash(:sha256, Enum.join(e.txs)), do: throw(%{error: :txs_hash_invalid})
        else
          if eh.txs_hash != Blake3.hash(Enum.join(e.txs)), do: throw(%{error: :txs_hash_invalid})
        end

        is_special_meeting_block = !!e[:mask]
        steam = Task.async_stream(e.txs, fn tx_packed ->
            %{error: err} = TX.validate(tx_packed, is_special_meeting_block)
            err
        end)
        err = Enum.find_value(steam, fn {:ok, result} -> result != :ok && result end)
        if err, do: throw(err)

        throw(%{error: :ok})
        catch
            :throw,r -> r
            e,r -> IO.inspect {Entry, :validate_entry, e, r}; %{error: :unknown}
        end
    end

    def validate_signature(e) do
        header = e.header
        hash = if header.height >= @forkheight do
          :crypto.hash(:sha256, RDB.vecpak_encode(header))
        else
          Blake3.hash(:erlang.term_to_binary(header, [:deterministic]))
        end
        mask = e[:mask]
        try do
          if mask do
              trainers = DB.Chain.validators_for_height(header.height)
              trainers_signed = BLS12AggSig.unmask_trainers(trainers, e.mask, e.mask_size)
              if nil in trainers_signed, do: throw(%{error: :wrong_epoch})

              aggpk = BlsEx.aggregate_public_keys!(trainers_signed)
              if !BlsEx.verify?(aggpk, e.signature, hash, BLS12AggSig.dst_entry()), do: throw(%{error: :invalid_mask_signature})
          else
              if !BlsEx.verify?(header.signer, e.signature, hash, BLS12AggSig.dst_entry()), do: throw(%{error: :invalid_signature})
          end
          %{error: :ok, hash: hash}
        catch
            :throw,r -> Map.put(r, :hash, hash)
            e,r -> IO.inspect({Entry, :validate_signature, e, r, __STACKTRACE__}, limit: 1111111); %{error: :unknown, hash: hash}
        end
    end

    def validate_next(cur_entry, next_entry) do
        try do
        ceh = cur_entry.header
        neh = next_entry.header
        if ceh.slot != neh.prev_slot, do: throw(%{error: :invalid_slot})
        if ceh.height != (neh.height - 1), do: throw(%{error: :invalid_height})
        if cur_entry.hash != neh.prev_hash, do: throw(%{error: :invalid_hash})

        if neh.height >= @forkheight do
          if :crypto.hash(:sha256, ceh.dr) != neh.dr, do: throw(%{error: :invalid_dr})
        else
          if Blake3.hash(ceh.dr) != neh.dr, do: throw(%{error: :invalid_dr})
        end
        if !BlsEx.verify?(neh.signer, neh.vr, ceh.vr, BLS12AggSig.dst_vrf()), do: throw(%{error: :invalid_vr})

        txus = Enum.map(next_entry.txs, & TX.unpack(&1))
        chain_epoch = DB.Chain.epoch()
        segment_vr_hash = DB.Chain.segment_vr_hash()
        diff_bits = DB.Chain.diff_bits()
        Enum.reduce(txus, %{}, fn(txu, batch_state)->
            case TXPool.validate_tx(txu, %{epoch: chain_epoch, segment_vr_hash: segment_vr_hash, diff_bits: diff_bits, batch_state: batch_state}) do
               %{error: :ok, batch_state: batch_state} -> batch_state
               %{error: error} when error in [:invalid_tx_nonce, :not_enough_tx_exec_balance] -> throw %{error: error}
               _ -> batch_state
            end
        end)

        %{error: :ok}
        catch
            :throw,r -> r
            e,r ->
                IO.inspect {Entry, :validate_next, e, r}
                %{error: :unknown}
        end
    end

    def build_next(sk, cur_entry) do
        pk = BlsEx.get_public_key!(sk)

        dr = if cur_entry.header.height >= (@forkheight - 1) do
          dr = :crypto.hash(:sha256, cur_entry.header.dr)
        else
          dr = Blake3.hash(cur_entry.header.dr)
        end
        vr = BlsEx.sign!(sk, cur_entry.header.vr, BLS12AggSig.dst_vrf())

        %{
            header: %{
                slot: cur_entry.header.slot + 1,
                height: cur_entry.header.height + 1,
                prev_slot: cur_entry.header.slot,
                prev_hash: cur_entry.hash,
                dr: dr,
                vr: vr,
                signer: pk,
            }
        }
    end

    def epoch(entry) do
        div(entry.header.height, 100_000)
    end

    def height(entry) do
        entry.header.height
    end

    def contains_tx(entry, txfunction) do
        !!Enum.find(entry.txs, fn(txp)->
            txu = TX.unpack(txp)
            action = List.first(txu.tx.actions)
            action["function"] == txfunction
        end)
    end
end

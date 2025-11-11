defmodule DB.Chain do
  import DB.API

  def tip(db_opts \\ %{}) do RocksDB.get("temporal_tip", db_handle(db_opts, :sysconf, %{})) end

  def tip_entry(db_opts \\ %{}) do
    DB.Entry.by_hash(tip(db_opts), db_opts)
  end

  def height(db_opts \\ %{}) do tip_entry(db_opts).header_unpacked.height end
  def epoch(db_opts \\ %{}) do div(height(db_opts), 100_000) end

  def rooted_tip(db_opts \\ %{}) do RocksDB.get("rooted_tip", db_handle(db_opts, :sysconf, %{})) end

  def rooted_tip_entry(db_opts \\ %{}) do
    DB.Entry.by_hash(rooted_tip(db_opts), db_opts)
  end

  def rooted_height(db_opts \\ %{}) do
      entry = rooted_tip_entry(db_opts)
      if entry do
          entry.header_unpacked.height
      end
  end

  def segment_vr_hash(db_opts \\ %{}) do
    RocksDB.get("bic:epoch:segment_vr_hash", db_handle(db_opts, :contractstate, %{}))
  end

  def diff_bits(db_opts \\ %{}) do
    RocksDB.get("bic:epoch:diff_bits", db_handle(db_opts, :contractstate, %{to_integer: true})) || 24
  end

  def total_sols(db_opts \\ %{}) do
    RocksDB.get("bic:epoch:total_sols", db_handle(db_opts, :contractstate, %{to_integer: true})) || 0
  end

  def pop(pk, db_opts \\ %{}) do
    RocksDB.get("bic:epoch:pop:#{pk}", db_handle(db_opts, :contractstate, %{}))
  end

  def nonce(pk, db_opts \\ %{}) do
    RocksDB.get("bic:base:nonce:#{pk}", db_handle(db_opts, :contractstate, %{to_integer: true}))
  end

  def balance(pk, symbol \\ "AMA", db_opts \\ %{}) do
    RocksDB.get("bic:coin:balance:#{pk}:#{symbol}", db_handle(db_opts, :contractstate, %{to_integer: true})) || 0
  end

  def tx(tx_hash, db_opts \\ %{}) do
      map = RocksDB.get(tx_hash, db_handle(db_opts, :tx, %{}))
      if map do
          map = map |> RDB.vecpak_decode()
          entry_bytes = RocksDB.get(map.entry_hash, db_handle(db_opts, :entry, %{}))
          entry = DB.Entry.by_hash(map.entry_hash, db_opts)
          tx_bytes = binary_part(entry_bytes, map.index_start, map.index_size)
          TX.unpack(tx_bytes)
          |> Map.put(:result, map[:result])
          |> Map.put(:metadata, %{entry_hash: map.entry_hash, entry_height: entry.header_unpacked.height, entry_slot: entry.header_unpacked.slot})
      end
  end

  # Validator
  def is_validator(pk \\ nil, db_opts \\ %{}) do
    pks = if pk do [pk] else
      Application.fetch_env!(:ama, :keys_all_pks)
    end
    validators = validators_for_height(height()+1, db_opts)
    delta = validators -- pks
    length(validators) != length(delta)
  end

  def validators_for_height(height, db_opts \\ %{}) do
    opts = db_handle(db_opts, :contractstate, %{term: true})
    cond do
        height in 3195570..3195575 ->
            RocksDB.get("bic:epoch:trainers:height:000000319557", opts)
        true ->
            {_, value} = RocksDB.get_prev_or_first("bic:epoch:trainers:height:", pad_integer(height), opts)
            value
    end
  end

  def validators_for_hash(hash, db_opts \\ %{}) do
    entry = DB.Entry.by_hash(hash)
    if entry do validators_for_height(entry.header_unpacked.height, db_opts) end
  end

  def validators_for_height_my(height, db_opts \\ %{}) do
    validators = validators_for_height(height, db_opts)
    Application.fetch_env!(:ama, :keys)
    |> Enum.filter(& &1.pk in validators)
    |> Enum.map(& &1.pk)
  end

  def validator_for_height(height, db_opts \\ %{}) do
    validators = validators_for_height(height, db_opts)
    index = rem(height, length(validators))
    Enum.at(validators, index)
  end

  def validator_for_height_current(db_opts \\ %{}) do
    validator_for_height(height(db_opts), db_opts)
  end

  def validator_for_height_next(db_opts \\ %{}) do
    validator_for_height(height(db_opts) + 1, db_opts)
  end


  #Rewind
  def rewind(target_hash) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    rtx = RocksDB.transaction(db)
    in_chain = DB.Entry.in_chain(target_hash, %{rtx: rtx})
    tip_entry = DB.Chain.tip_entry(%{rtx: rtx})

    target_hash_entry = DB.Entry.by_hash(target_hash, %{rtx: rtx})
    rooted_height = DB.Chain.rooted_height(%{rtx: rtx})

    cond do
      !in_chain or tip_entry.hash == target_hash ->
        RocksDB.transaction_rollback(rtx)
        false
      target_hash_entry.header_unpacked.height < rooted_height ->
        IO.inspect "cannot rewind finalized entry"
        RocksDB.transaction_rollback(rtx)
        false
      true ->
        rewind_1(tip_entry, target_hash, rtx)
        RocksDB.put("temporal_tip", target_hash, %{rtx: rtx, cf: cf.sysconf})
        :ok = RocksDB.transaction_commit(rtx)
        true
      end
  end
  defp rewind_1(current_entry, target_hash, rtx) do
    m_rev = DB.Entry.muts_rev(current_entry.hash, %{rtx: rtx})
    revert_muts(m_rev, %{rtx: rtx})

    DB.Entry.delete_UNSAFE(current_entry.hash, %{rtx: rtx})
    prev_hash = current_entry.header_unpacked.prev_hash
    if prev_hash == target_hash do
      :ok
    else
      rewind_1(DB.Entry.by_hash(prev_hash, %{rtx: rtx}), target_hash, rtx)
    end
  end

  def revert_muts(m_rev, db_opts = %{rtx: _}) do
    %{cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    Enum.reverse(m_rev)
    |> Enum.each(fn(mut)->
      case mut.op do
        :put ->
          RocksDB.put(mut.key, mut.value, %{rtx: db_opts.rtx, cf: cf.contractstate})
        :delete ->
          RocksDB.delete(mut.key, %{rtx: db_opts.rtx, cf: cf.contractstate})
        :clear_bit ->
          old_value = RocksDB.get(mut.key, %{rtx: db_opts.rtx, cf: cf.contractstate})
          << left::size(mut.value), _old_bit::size(1), right::bitstring >> = old_value
          new_value = << left::size(mut.value), 0::size(1), right::bitstring >>
          RocksDB.put(mut.key, new_value, %{rtx: db_opts.rtx, cf: cf.contractstate})
      end
    end)
  end
end

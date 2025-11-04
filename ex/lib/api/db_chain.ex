defmodule DB.Chain do
  import DB.API

  def tip(db_opts \\ %{}) do RocksDB.get("temporal_tip", db_handle(db_opts, :sysconf, %{})) end

  def tip_entry(db_opts \\ %{}) do
    entry(tip(db_opts), db_opts)
  end

  def height(db_opts \\ %{}) do tip_entry(db_opts).header_unpacked.height end
  def epoch(db_opts \\ %{}) do div(height(db_opts), 100_000) end

  def rooted_tip(db_opts \\ %{}) do RocksDB.get("rooted_tip", db_handle(db_opts, :sysconf, %{})) end

  def rooted_tip_entry(db_opts \\ %{}) do
    entry(rooted_tip(db_opts), db_opts)
  end

  def rooted_height(db_opts \\ %{}) do
      entry = rooted_tip_entry(db_opts)
      if entry do
          entry.header_unpacked.height
      end
  end

  def muts(hash, db_opts \\ %{}) do RocksDB.get(hash, db_handle(db_opts, :muts, %{term: true})) end
  def muts_rev(hash, db_opts \\ %{}) do RocksDB.get(hash, db_handle(db_opts, :muts_rev, %{term: true})) end

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

  def entry(hash, db_opts \\ %{}) do
    RocksDB.get(hash, db_handle(db_opts, :entry, %{term: true}))
    |> Entry.unpack()
  end

  def entries_by_height(height, db_opts \\ %{}) do
    RocksDB.get_prefix("#{height}:", db_handle(db_opts, :entry_by_height, %{}))
    |> Enum.map(& Entry.unpack( entry(elem(&1,0), db_opts) ))
  end

  def entry_seentime(hash, db_opts \\ %{}) do
    RocksDB.get(hash, db_handle(db_opts, :my_seen_time_for_entry, %{term: true}))
  end

  def tx(tx_hash, db_opts \\ %{}) do
      map = RocksDB.get(tx_hash, db_handle(db_opts, :tx, %{term: true}))
      if map do
          entry_bytes = RocksDB.get(map.entry_hash, db_handle(db_opts, :entry, %{}))
          entry = DB.Chain.entry(map.entry_hash)
          tx_bytes = binary_part(entry_bytes, map.index_start, map.index_size)
          TX.unpack(tx_bytes)
          |> Map.put(:result, map[:result])
          |> Map.put(:metadata, %{entry_hash: map.entry_hash, entry_height: entry.header_unpacked.height, entry_slot: entry.header_unpacked.slot})
      end
  end

  """
  [entry]
  hash blob

  [entry_meta]
  seentime:{hash} "{ts_millisecond}"
  height:{height}:{hash} hash

  prev:{hash} hash
  next:{hash} hash
  in_chain:{hash} "" / None
  in_chain_height:{height} hash

  [attestation]
  attestation:{hash}:{signer}:{muthash} attestation
  attestation_agg:{hash}:{muthash} consensus

  [tx]
  tx:{txhash} "{index_ptr_map}"

  [tx_meta]
  tx_out:{account}:{nonce} txhash
  tx_in:{account}:{nonce} txhash
  "tx_account_nonce|account:nonce->txhash",
  "tx_receiver_nonce|receiver:nonce->txhash",
  """


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
            {_, value} = RocksDB.get_prev_or_first("bic:epoch:trainers:height:", String.pad_leading("#{height}", 12, "0"), opts)
            value
    end
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
end

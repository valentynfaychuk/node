defmodule DB.Entry do
  import DB.API

  def by_hash(hash, db_opts \\ %{}) do
    RocksDB.get(hash, db_handle(db_opts, :entry, %{}))
    |> Entry.unpack_from_db()
  end

  def fix_entry(hash, db_opts \\ %{}) do
    e = RocksDB.get(hash, db_handle(db_opts, :entry, %{}))
    |> Entry.unpack_from_db()
    if is_binary(e.header_unpacked) do
      if e[:mask] do IO.inspect(e, limit: 11111111); throw %{error: :has_mask} end
      entry = Map.put(e, :header, :erlang.binary_to_term(e.header_unpacked))
      entry = Map.put(e, :header_unpacked, :erlang.binary_to_term(e.header_unpacked))
      entry_packed = Entry.pack_for_db(entry)
      RocksDB.put(entry.hash, entry_packed, db_handle(db_opts, :entry, %{}))
    end
  end

  def by_height(height, db_opts \\ %{}) do
    RocksDB.get_prefix("by_height:#{pad_integer(height)}:", db_handle(db_opts, :entry_meta, %{}))
    |> Enum.map(& by_hash(elem(&1,0), db_opts) )
  end

  def by_height_return_hashes(height, db_opts \\ %{}) do
    RocksDB.get_prefix("by_height:#{pad_integer(height)}:", db_handle(db_opts, :entry_meta, %{}))
    |> Enum.map(& elem(&1,0))
  end

  def by_height_in_main_chain(height, db_opts \\ %{}) do
    RocksDB.get("by_height_in_main_chain:#{pad_integer(height)}", db_handle(db_opts, :entry_meta, %{}))
  end

  def seentime(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:seentime", db_handle(db_opts, :entry_meta, %{to_integer: true}))
  end

  def muts_hash(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:muts_hash", db_handle(db_opts, :entry_meta, %{}))
  end

  def prev(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:prev", db_handle(db_opts, :entry_meta, %{}))
  end

  def next(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:next", db_handle(db_opts, :entry_meta, %{}))
  end

  def in_chain(hash, db_opts \\ %{}) do
    !!RocksDB.get("entry:#{hash}:in_chain", db_handle(db_opts, :entry_meta, %{}))
  end

  def muts(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:muts", db_handle(db_opts, :entry_meta, %{}))
    |> RDB.vecpak_decode()
  end

  def muts_rev(hash, db_opts \\ %{}) do
    RocksDB.get("entry:#{hash}:muts_rev", db_handle(db_opts, :entry_meta, %{}))
    |> RDB.vecpak_decode()
  end

  def insert(entry, db_opts \\ %{}) when is_map(entry) do
    db_opts = if db_opts[:rtx] do db_opts else
      %{db: db, cf: _cf} = :persistent_term.get({:rocksdb, Fabric})
      rtx = RocksDB.transaction(db)
      db_opts = Map.put(db_opts, :rtx, rtx)
      Map.put(db_opts, :rtx_commit, true)
    end

    entry_packed = Entry.pack_for_db(entry)
    if !by_hash(entry.hash, db_opts) do
      RocksDB.put(entry.hash, entry_packed, db_handle(db_opts, :entry, %{}))
      RocksDB.put("by_height:#{pad_integer(entry.header.height)}:#{entry.hash}", entry.hash, db_handle(db_opts, :entry_meta, %{}))
      RocksDB.put("entry:#{entry.hash}:seentime", :os.system_time(1000), db_handle(db_opts, :entry_meta, %{to_integer: true}))
    end

    db_opts[:rtx_commit] && RocksDB.transaction_commit(db_opts.rtx)
  end

  def apply_into_main_chain(entry, muts_hash, muts_rev, receipts, db_opts = %{rtx: _}) do
    entry_packed = Entry.pack_for_db(entry)
    RocksDB.put(entry.hash, entry_packed, db_handle(db_opts, :entry, %{}))
    RocksDB.put("by_height:#{pad_integer(entry.header.height)}:#{entry.hash}", entry.hash, db_handle(db_opts, :entry_meta, %{}))
    RocksDB.put("by_height_in_main_chain:#{pad_integer(entry.header.height)}", entry.hash, db_handle(db_opts, :entry_meta, %{}))
    #RocksDB.put("entry:#{entry.hash}:seentime", :os.system_time(1000), db_handle(db_opts, :entry_meta, %{to_integer: true}))
    RocksDB.put("entry:#{entry.hash}:prev", entry.header.prev_hash, db_handle(db_opts, :entry_meta, %{}))
    RocksDB.put("entry:#{entry.header.prev_hash}:next", entry.hash, db_handle(db_opts, :entry_meta, %{}))
    RocksDB.put("entry:#{entry.hash}:in_chain", "", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.put("entry:#{entry.hash}:muts_hash", muts_hash, db_handle(db_opts, :entry_meta, %{}))
    RocksDB.put("entry:#{entry.hash}:muts_rev", RDB.vecpak_encode(muts_rev), db_handle(db_opts, :entry_meta, %{}))

    Enum.each(Enum.zip(entry.txs, receipts), fn({tx_packed, result})->
        txu = TX.unpack(tx_packed)
        case :binary.match(entry_packed, tx_packed) do
          {index_start, index_size} ->
            tx_ptr = %{entry_hash: entry.hash, result: result, index_start: index_start, index_size: index_size}
            |> RDB.vecpak_encode()
            RocksDB.put(txu.hash, tx_ptr, db_handle(db_opts, :tx, %{}))

            nonce_padded = pad_integer_20(txu.tx.nonce)
            RocksDB.put("#{txu.tx.signer}:#{nonce_padded}", txu.hash, db_handle(db_opts, :tx_account_nonce, %{}))
            TX.known_receivers(txu)
            |> Enum.each(fn(receiver)->
                RocksDB.put("#{receiver}:#{nonce_padded}", txu.hash, db_handle(db_opts, :tx_receiver_nonce, %{}))
            end)
        end
    end)
  end

  def apply_into_main_chain_muts(hash, muts, db_opts = %{rtx: _}) do
    RocksDB.put("entry:#{hash}:muts", RDB.vecpak_encode(muts), db_handle(db_opts, :entry_meta, %{}))
  end

  def delete_UNSAFE(_a, _db_opts \\ %{})
  def delete_UNSAFE(nil, _db_opts) do nil end
  def delete_UNSAFE(hash, db_opts) when is_binary(hash) do
    entry = by_hash(hash)
    delete_UNSAFE(entry, db_opts)
  end
  def delete_UNSAFE(entry, db_opts = %{rtx: _}) when is_map(entry) do
    hash = entry.hash

    RocksDB.delete(hash, db_handle(db_opts, :entry, %{}))

    height_padded = pad_integer(entry.header.height)
    main_chain_hash = RocksDB.get("by_height_in_main_chain:#{height_padded}", db_handle(db_opts, :entry_meta, %{}))
    if hash == main_chain_hash do
      RocksDB.delete("by_height_in_main_chain:#{height_padded}", db_handle(db_opts, :entry_meta, %{}))
      RocksDB.delete("entry:#{entry.header.prev_hash}:next", db_handle(db_opts, :entry_meta, %{}))
    end
    RocksDB.delete("by_height:#{height_padded}:#{hash}", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:seentime", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:muts_hash", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:prev", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:next", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:in_chain", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:muts", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete("entry:#{hash}:muts_rev", db_handle(db_opts, :entry_meta, %{}))
    RocksDB.delete_prefix("consensus:#{hash}:", db_handle(db_opts, :attestation, %{}))
    RocksDB.delete_prefix("attestation:#{height_padded}:#{hash}:", db_handle(db_opts, :attestation, %{}))

    Enum.each(entry.txs, fn(tx_packed)->
        txu = TX.unpack(tx_packed)
        RocksDB.delete(txu.hash, db_handle(db_opts, :tx, %{}))

        nonce_padded = pad_integer_20(txu.tx.nonce)
        RocksDB.delete("#{txu.tx.signer}:#{nonce_padded}", db_handle(db_opts, :tx_account_nonce, %{}))
        TX.known_receivers(txu)
        |> Enum.each(fn(receiver)->
            RocksDB.delete("#{receiver}:#{nonce_padded}", db_handle(db_opts, :tx_receiver_nonce, %{}))
        end)
    end)
  end

end

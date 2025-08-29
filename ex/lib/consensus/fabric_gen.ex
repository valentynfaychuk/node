defmodule FabricGen do
  use GenServer

  def isSyncing() do
    case :persistent_term.get(FabricSyncing, nil) do
      nil -> false
      atomic -> :atomics.get(atomic, 1) == 1
    end
  end

  def exitAfterMySlot() do
    :persistent_term.put(:exit_after_my_slot, true)
  end

  def snapshotBeforeMySlot() do
    :persistent_term.put(:snapshot_before_my_slot, true)
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :persistent_term.put(FabricSyncing, :atomics.new(1, []))

    :erlang.send_after(2500, self(), :tick)
    :erlang.send_after(2500, self(), :tick_purge_txpool)
    {:ok, state}
  end

  def handle_info(:tick_purge_txpool, state) do
    :erlang.spawn(fn()->
      task = Task.async(fn -> TXPool.purge_stale() end)
      try do
        Task.await(task, 600)
      catch
        :exit, {:timeout, _} -> Task.shutdown(task, :brutal_kill)
      end
    end)

    :erlang.send_after(6000, self(), :tick_purge_txpool)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = if true do tick(state) else state end
    :erlang.send_after(100, self(), :tick)
    {:noreply, state}
  end

  def handle_info(:tick_oneshot, state) do
    if !state[:timer_oneshot_ref] do
      ref = Process.send_after(self(), :tick_oneshot_resolve, 50)
      {:noreply, Map.put(state, :timer_oneshot_ref, ref)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:tick_oneshot_resolve, state) do
    tick(state)
    {:noreply, Map.delete(state, :timer_oneshot_ref)}
  end

  def tick(state) do
    :persistent_term.get(FabricSyncing) |> :atomics.put(1, 1)

    proc_consensus()
    proc_entries()
    tick_slot(state)

    :persistent_term.get(FabricSyncing) |> :atomics.put(1, 0)
    state
  end

  def tick_slot(state) do
    #IO.inspect "tick_slot"
    if proc_if_my_slot() do
      proc_entries()
      #proc_compact()
      if :persistent_term.get(:exit_after_my_slot, nil) do
        :erlang.halt()
      end
    end

    state
  end

  def proc_compact() do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    ts_m = :os.system_time(1000)
    #:ok = :rocksdb.sync_wal(db)
    RocksDB.flush_all(db, cf)
    RocksDB.compact_all(db, cf)
    took = :os.system_time(1000) - ts_m
    if took > 1000 do
      IO.puts "compact_took #{took}"
    end
  end

  def proc_consensus() do
    entry_root = Fabric.rooted_tip_entry()
    entry_temp = Consensus.chain_tip_entry()
    height_root = entry_root.header_unpacked.height
    height_temp = entry_temp.header_unpacked.height
    if height_root < height_temp do
      proc_consensus_1(height_root+1)
    end
  end

  def best_entry_for_height(height) do
    rooted_tip = Fabric.rooted_tip()
    next_entries = height
    |> Fabric.entries_by_height()
    |> Enum.filter(& &1.header_unpacked.prev_hash == rooted_tip)
    |> Enum.map(fn(entry)->
        trainers = Consensus.trainers_for_height(Entry.height(entry))
        {mut_hash, score, _consensus} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {-score, entry.header_unpacked.slot, !entry[:mask], entry.hash} end)
  end

  def best_entry_for_height_no_score(height) do
    rooted_tip = Fabric.rooted_tip()
    next_entries = height
    |> Fabric.entries_by_height()
    |> Enum.filter(& &1.header_unpacked.prev_hash == rooted_tip)
    |> Enum.map(fn(entry)->
        trainers = Consensus.trainers_for_height(Entry.height(entry))
        {mut_hash, score, _consensus} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {entry.header_unpacked.slot, !entry[:mask], entry.hash} end)
  end

  defp proc_consensus_1(next_height) do
    next_entries = best_entry_for_height(next_height)

    #IO.inspect {next_entries, next_height}
    case List.first(next_entries) do
        #TODO: adjust the maliciousness rate via score
        {best_entry, mut_hash, score} when score >= 0.67 ->
            mymut = Fabric.my_attestation_by_entryhash(best_entry.hash)
            cond do
              !mymut ->
                IO.puts "softfork: rewind to entry #{Base58.encode(best_entry.hash)}, height #{best_entry.header_unpacked.height}"
                {entry, mut_hash, score} = List.first(best_entry_for_height(next_height - 1))
                true = Consensus.chain_rewind(entry.hash)
                proc_consensus()

              mut_hash != mymut.mutations_hash ->
                height = best_entry.header_unpacked.height
                slot = best_entry.header_unpacked.slot
                IO.puts "EMERGENCY: consensus chose entry #{Base58.encode(best_entry.hash)} for height/slot #{height}/#{slot}"
                IO.puts "but our mutations are #{Base58.encode(mymut[:mutations_hash])} while consensus is #{Base58.encode(mut_hash)}"
                IO.puts "EMERGENCY: consensus halted as state is out of sync with network"
                {entry, mut_hash, score} = List.first(best_entry_for_height(next_height - 1))
                true = Consensus.chain_rewind(entry.hash)
                :erlang.halt()

              true ->
                FabricEventGen.event_rooted(best_entry, mut_hash)
                Fabric.set_rooted_tip(best_entry.hash)
                proc_consensus()
            end
        _ -> nil
    end
  end

  def proc_entries() do
    softfork_hash = :persistent_term.get(SoftforkHash, [])
    softfork_deny_hash = :persistent_term.get(SoftforkDenyHash, [])

    cur_entry = Consensus.chain_tip_entry()
    cur_slot = cur_entry.header_unpacked.slot
    height = cur_entry.header_unpacked.height
    next_height = height + 1
    next_entries = next_height
    |> Fabric.entries_by_height()
    |> Enum.filter(fn(next_entry)->
      #in slot
      next_slot = next_entry.header_unpacked.slot
      trainer_for_slot = Consensus.trainer_for_slot(Entry.height(next_entry), next_slot)
      in_slot = cond do
        next_entry.header_unpacked.signer == trainer_for_slot -> true
        !!next_entry[:mask] ->
            trainers = Consensus.trainers_for_height(Entry.height(next_entry))
            score = BLS12AggSig.score(trainers, next_entry.mask)
            score >= 0.67

        true -> false
      end

      #is incremental slot
      slot_delta = next_slot - cur_slot

      cond do
        !in_slot -> false
        slot_delta != 1 -> false
        next_entry.hash in softfork_deny_hash -> false
        Entry.validate_next(cur_entry, next_entry) != %{error: :ok} -> false
        true -> true
      end
    end)
    |> Enum.sort_by(& {&1.hash not in softfork_hash, &1.header_unpacked.slot, !&1[:mask], &1.hash})

    case List.first(next_entries) do
      nil -> nil
      entry ->
        #ts_s = :os.system_time(1000)
        #%{error: :ok, attestation_packed: attestation_packed,
        #  mutations_hash: m_hash, logs: l, muts: m} = Consensus.apply_entry(entry)
        #IO.inspect {:took, entry.header_unpacked.height, :os.system_time(1000) - ts_s}

        task = Task.async(fn -> Consensus.apply_entry(entry) end)
        %{error: :ok, attestation_packed: attestation_packed,
          mutations_hash: m_hash, logs: l, muts: m
        } = case Task.await(task, :infinity) do
          result = %{error: :ok} -> result
        end

        FabricEventGen.event_applied(entry, m_hash, m, l)

        if !!attestation_packed and FabricSyncAttestGen.isQuorumSyncedOffByX(6) do
          NodeGen.broadcast(:attestation_bulk, :trainers, [[attestation_packed]])
          NodeGen.broadcast(:attestation_bulk, {:not_trainers, 10}, [[attestation_packed]])
        end

        TXPool.delete_packed(entry.txs)

        proc_entries()
    end
  end

  def proc_if_my_slot() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()
    next_slot = entry.header_unpacked.slot + 1
    next_height = entry.header_unpacked.height + 1
    slot_trainer = Consensus.trainer_for_slot(next_height, next_slot)

    #prevent double-entries due to severe system lag (you shouldnt be validator in the first place)
    lastSlot = :persistent_term.get(:last_made_entry_slot, nil)

    rooted_tip = Fabric.rooted_tip()
    emptyHeight = Fabric.entries_by_height(next_height)
    |> Enum.filter(& &1.header_unpacked.prev_hash == rooted_tip)
    emptyHeight = emptyHeight == []

    cond do
      !FabricSyncAttestGen.isQuorumSynced() -> nil

      lastSlot == next_slot -> nil
      !emptyHeight -> nil

      pk == slot_trainer ->
        :persistent_term.put(:last_made_entry_slot, next_slot)

        if :persistent_term.get(:snapshot_before_my_slot, nil) do
          :persistent_term.erase(:snapshot_before_my_slot)
          IO.inspect "taking snapshot #{Fabric.rooted_tip_height()}"
          FabricSnapshot.snapshot_tmp()
        end

        IO.puts "🔧 im in slot #{next_slot}, working.. *Click Clak*"

        #%{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        #:rocksdb.checkpoint(db, '/tmp/mig/db/fabric/')

        proc_if_my_slot_1(next_slot)

      true ->
        nil
    end
  end

  def proc_if_my_slot_1(next_slot) do
    next_entry = Consensus.produce_entry(next_slot)
    Fabric.insert_entry(next_entry, :os.system_time(1000))

    map = %{entry_packed: Entry.pack(next_entry)}

    next_trainer = Consensus.trainer_for_slot(Entry.height(next_entry)+1, next_slot+1)
    peer = NodePeers.by_pk(next_trainer)
    if peer do NodeGen.broadcast(:entry, {:some, [peer.ip]}, [map]) end
    next_trainer = Consensus.trainer_for_slot(Entry.height(next_entry)+2, next_slot+2)
    peer2 = NodePeers.by_pk(next_trainer)
    if peer2 do NodeGen.broadcast(:entry, {:some, [peer2.ip]}, [map]) end

    NodeGen.broadcast(:entry, :trainers, [map])
    NodeGen.broadcast(:entry, {:not_trainers, 10}, [map])
    next_entry
  end
end

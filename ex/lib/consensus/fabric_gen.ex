defmodule FabricGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(2500, self(), :tick)
    :erlang.send_after(3000, self(), :tick_slot)
    :erlang.send_after(5000, self(), :tick_slash)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    state = if true do tick(state) else state end
    :erlang.send_after(100, self(), :tick)
    {:noreply, state}
  end

  def handle_info(:tick_slot, state) do
    state = if true do tick_slot(state) else state end
    :erlang.send_after(100, self(), :tick_slot)
    {:noreply, state}
  end

  def handle_info(:tick_slash, state) do
    if proc_entries_slash() do
      proc_entries()
    end
    :erlang.send_after(3000, self(), :tick_slash)
    {:noreply, state}
  end

  def tick(state) do
    #IO.inspect "tick"
    
    proc_entries()
    proc_consensus()

    #TODO: check if reorg needed
    TXPool.purge_stale()

    state
  end

  def tick_slot(state) do
    #IO.inspect "tick_slot"
    if proc_if_my_slot() do
      proc_entries()
    end

    #proc_compact()

    state
  end

  def proc_compact() do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    ts_m = :os.system_time(1000)
    RocksDB.compact_all(db, cf)
    IO.puts "compact_took #{:os.system_time(1000) - ts_m}"
  end

  def proc_consensus() do
    entry = Fabric.rooted_tip_entry()
    entry_temp = Consensus.chain_tip_entry()
    height = entry.header_unpacked.height
    height_temp = entry_temp.header_unpacked.height
    if height < height_temp do
      proc_consensus_1(entry, height)
    end
  end

  def best_entry_for_height(height) do
    next_entries = Fabric.entries_by_height(height)
    Enum.map(next_entries, fn(entry)->
        trainers = Consensus.trainers_for_height(Entry.height(entry))
        {mut_hash, score, _consensus} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {score, -entry.header_unpacked.slot, entry.hash} end, :desc)
  end

  defp proc_consensus_1(entry, height) do
    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.map(next_entries, fn(entry)->
        trainers = Consensus.trainers_for_height(Entry.height(entry))
        {mut_hash, score, _consensus} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {score, -entry.header_unpacked.slot, entry.hash} end, :desc)
    case List.first(next_entries) do
        #TODO: adjust the maliciousness rate via score
        {best_entry, mut_hash, score} when score >= 0.6 ->
            mymut = Fabric.my_attestation_by_entryhash(best_entry.hash)
            cond do
              !mymut ->
                IO.puts "softfork: rewind to entry #{Base58.encode(best_entry.hash)}, height #{best_entry.header_unpacked.height}"
                {entry, mut_hash, score} = List.first(best_entry_for_height(best_entry.header_unpacked.height - 1))
                true = Consensus.chain_rewind(entry.hash)
                proc_consensus()

              mut_hash != mymut.mutations_hash ->
                height = best_entry.header_unpacked.height
                slot = best_entry.header_unpacked.slot
                IO.puts "EMERGENCY: consensus chose entry #{Base58.encode(best_entry.hash)} for height/slot #{height}/#{slot}"
                IO.puts "but our mutations are #{Base58.encode(mymut[:mutations_hash])} while consensus is #{Base58.encode(mut_hash)}"
                IO.puts "EMERGENCY: consensus halted as state is out of sync with network"
                :erlang.halt()

              true ->
                Fabric.set_rooted_tip(best_entry.hash)
                proc_consensus()
            end
        _ -> nil
    end
  end

  def proc_entries_slash() do
    cur_entry = Consensus.chain_tip_entry()
    cur_slot = cur_entry.header_unpacked.slot
    cur_height = cur_entry.header_unpacked.height
  
    trainers = Consensus.trainers_for_height(Entry.height(cur_entry))
    max_backsight = length(trainers)
    Enum.reduce_while(cur_height..(cur_height-max_backsight), nil, fn(height, _)->
      entries = Fabric.entries_by_height(height)
      entryIsSlash = Enum.find(entries, fn(entry)->
        Enum.find(entry.txs, fn(txp)->
          txu = TX.unpack(txp)
          action = List.first(txu.tx.actions)
          if action[:function] == "slash_trainer" do
            [epoch, malicious_pk, signature, mask_size, mask] = action.args
            if !BIC.Epoch.slash_trainer_verify(epoch, malicious_pk, trainers, mask, signature) do
              true
            end
          end
        end)
      end)
      cond do
        length(entries) <= 1 -> {:cont, nil}
        entryIsSlash ->
          in_chain = Consensus.is_in_chain(entryIsSlash.hash)
          if !in_chain do
            IO.inspect {:not_in_chain, :fixing}
            entry_to_revert = entries
            |> Enum.find_value(& Consensus.is_in_chain(&1.hash) and &1)
            IO.inspect {:revert, entry_to_revert.hash}
            Consensus.chain_rewind(entry_to_revert.hash)
            {:halt, entry_to_revert.hash}
          else
            {:cont, nil}
          end
        true -> {:cont, nil}
      end
    end)
  end

  def proc_entries() do
    cur_entry = Consensus.chain_tip_entry()
    cur_slot = cur_entry.header_unpacked.slot
    height = cur_entry.header_unpacked.height

    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.filter(next_entries, fn(next_entry)->
      #in slot
      next_slot = next_entry.header_unpacked.slot
      trainer_for_slot = Consensus.trainer_for_slot(Entry.height(next_entry), next_slot)
      in_slot = next_entry.header_unpacked.signer == trainer_for_slot

      #is incremental slot
      slot_delta = next_slot - cur_slot

      cond do
        !in_slot -> false
        slot_delta != 1 -> false
        Entry.validate_next(cur_entry, next_entry) != %{error: :ok} -> false
        true -> true
      end
    end)
    |> Enum.sort_by(& {!Entry.contains_tx(&1, "slash_trainer"), &1.header_unpacked.slot, &1.hash}, :desc)
    case List.first(next_entries) do
      nil -> nil
      entry ->
        %{error: :ok, attestation_packed: attestation_packed} = Consensus.apply_entry(entry)
        if attestation_packed do
          map = %{entry_packed: Entry.pack(entry)}
          NodeGen.broadcast(:entry, :trainers, [map])
          NodeGen.broadcast(:entry, 3, [map])

          NodeGen.broadcast(:attestation_bulk, :trainers, [[attestation_packed]])
          NodeGen.broadcast(:attestation_bulk, 3, [[attestation_packed]])
        end
        proc_entries()
    end
  end

  def proc_if_my_slot() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()
    next_slot = entry.header_unpacked.slot + 1
    next_height = entry.header_unpacked.height + 1
    slot_trainer = Consensus.trainer_for_slot(next_height, next_slot)

    cond do
      !FabricSyncGen.isQuorumSynced() -> nil

      pk == slot_trainer ->
        IO.puts "🔧 im in slot #{next_slot}, working.. *Click Clak*"
        proc_if_my_slot_1(next_slot)

      true ->
        nil
    end
  end

  def proc_if_my_slot_1(next_slot) do
    next_entry = Consensus.produce_entry(next_slot)
    Fabric.insert_entry(next_entry, :os.system_time(1000))

    map = %{entry_packed: Entry.pack(next_entry)}

    next_trainer = Consensus.trainer_for_slot(Entry.height(next_entry), next_slot+1)
    peer = NodePeers.by_pk(next_trainer)
    if peer do
      NodeGen.broadcast(:entry, {:some, [peer.ip]}, [map])
      Process.sleep(0x10)
    end

    NodeGen.broadcast(:entry, :trainers, [map])
    NodeGen.broadcast(:entry, 3, [map])
    next_entry
  end
end

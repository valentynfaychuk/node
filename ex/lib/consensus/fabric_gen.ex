defmodule FabricGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(2500, self(), :tick)
    :erlang.send_after(3000, self(), :tick_slot)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    state = if true do tick(state) else state end
    :erlang.send_after(100, self(), :tick)
    {:noreply, state}
  end

  def handle_info(:tick_slot, state) do
    state = if true do tick_slot(state) else state end
    :erlang.send_after(3000, self(), :tick_slot)
    {:noreply, state}
  end

  def handle_info({:insert_entry_attestation, entry, attestation, seen_time}, state) do
    Fabric.insert_entry(entry, seen_time)
    Fabric.aggregate_attestation(attestation)
    {:noreply, state}
  end

  def handle_info({:insert_entry, entry, seen_time}, state) do
    Fabric.insert_entry(entry, seen_time)
    {:noreply, state}
  end

  def handle_info({:add_attestation, attestation}, state) do
    Fabric.aggregate_attestation(attestation)
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
    
    next_entry = proc_if_my_slot()
    if next_entry do
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
        trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))
        {mut_hash, score} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {score, -entry.header_unpacked.slot, entry.hash} end, :desc)
  end

  def broadcast_for_next_few_entries(height) do
    next_entries1 = Fabric.entries_by_height(height+1)
    next_entries2 = Fabric.entries_by_height(height+2)
    next_entries3 = Fabric.entries_by_height(height+3)
    next_entries4 = Fabric.entries_by_height(height+4)
    next_entries5 = Fabric.entries_by_height(height+5)
    next_entries6 = Fabric.entries_by_height(height+6)
    List.flatten([next_entries1, next_entries2, next_entries3, next_entries4, next_entries5, next_entries6])
    |> Enum.each(fn(entry)->
        NodeGen.broadcast_need_attestation(entry)
    end)
  end

  defp proc_consensus_1(entry, height) do
    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.map(next_entries, fn(entry)->
        trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))
        {mut_hash, score} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        NodeGen.broadcast_need_attestation(entry)

        #TODO: fix this later, for faster sync
        h = Consensus.chain_tip_entry()
        hr = Fabric.rooted_tip_entry()
        if abs(h.header_unpacked.height - hr.header_unpacked.height) >= 6 do
          broadcast_for_next_few_entries(height+1)
        end

        #IO.inspect {entry, mut_hash, score}
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

  def proc_entries() do
    cur_entry = Consensus.chain_tip_entry()
    cur_slot = cur_entry.header_unpacked.slot
    height = cur_entry.header_unpacked.height
    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.filter(next_entries, fn(next_entry)->
      delta = abs(:os.system_time(1000) - Fabric.entry_seentime(next_entry.hash))
      max_skipped_slot_offset = div(delta, 3_000) + 1
      next_slot = next_entry.header_unpacked.slot
      slot_delta = next_slot - cur_slot

      trainer_for_slot = Consensus.trainer_for_slot(Entry.epoch(next_entry), next_slot)
      in_slot = next_entry.header_unpacked.signer == trainer_for_slot

      valid = Entry.validate_next(cur_entry, next_entry) == %{error: :ok}
      
      #highest_slot = :persistent_term.get(:highest_slot, 0)
      #slotBehind = (highest_slot - cur_slot) >= 3
      #IO.inspect {valid, in_slot, slot_delta, max_skipped_slot_offset}
      cond do
        !valid -> false
        !in_slot -> false
        slot_delta <= 0 -> false
        slot_delta > 1 + max_skipped_slot_offset -> false
        true -> true
      end
    end)
    |> Enum.sort_by(& {&1.header_unpacked.slot, &1.hash}, :desc)
    case List.first(next_entries) do
      nil -> nil
      entry -> 
        %{error: :ok, attestation_packed: attestation_packed} = Consensus.apply_entry(entry)
        if attestation_packed do
          NodeGen.broadcast_attestation(attestation_packed)
        end
        :persistent_term.put(:last_entry_applied, :os.system_time(1000))
        proc_entries()
    end
  end

  def proc_if_my_slot() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()
    my_height = entry.header_unpacked.height
    highest_height = max(my_height, :persistent_term.get(:highest_height, 0))
    slot = entry.header_unpacked.slot
    next_slot = slot + 1
    next_epoch = div(my_height+1, 100_000)
    slot_trainer = Consensus.trainer_for_slot(next_epoch, next_slot)
    peer_cnt = length(NodeGen.peers_online()) + 1

    delta = abs(:os.system_time(1000) - Fabric.entry_seentime(entry.hash))
    max_skipped_slot_offset = div(delta, 3_000)
    slots_to_skip = Consensus.next_trainer_slot_in_x_slots(pk, next_epoch, next_slot)

    trainers = Consensus.trainers_for_epoch(next_epoch)
    sync_round_offset = rem(div(:os.system_time(1), 3), length(trainers))
    sync_round_index = Enum.find_index(trainers, fn t -> t == pk end)

    #IO.inspect {:if_my_slot, pk == slot_trainer, next_slot, delta, slots_to_skip, max_skipped_slot_offset}
    cond do
      peer_cnt < Application.fetch_env!(:ama, :quorum) ->
        nil

      #TODO: confirm a valid entry with that height/hash otherwise they can lie to stall us
      pk == slot_trainer and highest_height - my_height > 0 ->
        IO.puts "🔴 inslot: my_height #{my_height} chain_height #{highest_height}"
        nil

      pk == slot_trainer ->
        #IO.puts "🔧 im in slot #{next_slot}, working.. *Click Clak*"
        next_entry = Consensus.produce_entry(next_slot)
        #IO.puts "entry #{entry.header_unpacked.height} produced."
        NodeGen.broadcast_entry(next_entry)
        next_entry

      #pk in Consensus.trainers_for_epoch(next_epoch) and slots_to_skip <= max_skipped_slot_offset and highest_height - my_height > 0 ->
      pk in Consensus.trainers_for_epoch(next_epoch) and slots_to_skip >= 1 and slots_to_skip <= max_skipped_slot_offset and sync_round_offset == sync_round_index and highest_height - my_height > 0 ->
        IO.puts "🔴 skipslot: my_height #{my_height} chain_height #{highest_height}"
        nil

      #pk in Consensus.trainers_for_epoch(next_epoch) and slots_to_skip <= max_skipped_slot_offset ->
      pk in Consensus.trainers_for_epoch(next_epoch) and slots_to_skip >= 1 and slots_to_skip <= max_skipped_slot_offset and sync_round_offset == sync_round_index ->
        IO.puts "🔧 skipped #{slots_to_skip} slots | #{next_slot + slots_to_skip}, working.. *Click Clak*"
        next_entry = Consensus.produce_entry(next_slot + slots_to_skip)
        #IO.puts "entry #{entry.header_unpacked.height} produced."
        NodeGen.broadcast_entry(next_entry)
        next_entry

      true ->
        nil
    end
  end
end
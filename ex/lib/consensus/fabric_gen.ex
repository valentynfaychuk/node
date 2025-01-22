defmodule FabricGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(3000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    state = if true do tick(state) else state end
    :erlang.send_after(100, self(), :tick)
    {:noreply, state}
  end

  def handle_info({:insert_entry, entry}, state) do
    Fabric.insert_entry(entry)
    {:noreply, state}
  end

  def handle_info({:add_attestation, attestation}, state) do
    Fabric.aggregate_attestation(attestation)
    {:noreply, state}
  end

  def tick(state) do
    #IO.inspect "tick"
      
    proc_consensus()
    proc_entries()

    next_entry = proc_if_my_slot()
    if next_entry do
      proc_entries()
    end

    #proc_compact()

    #TODO: check if reorg needed

    TXPool.purge_stale()

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

  defp proc_consensus_1(entry, height) do
    trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))
    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.map(next_entries, fn(entry)->
        {mut_hash, score} = Fabric.best_consensus_by_entryhash(trainers, entry.hash)
        NodeGen.broadcast_need_attestation(entry)
        {entry, mut_hash, score}
    end)
    |> Enum.filter(fn {entry, mut_hash, score} -> mut_hash end)
    |> Enum.sort_by(fn {entry, mut_hash, score} -> {score, entry.hash} end, :desc)
    case List.first(next_entries) do
        #TODO: adjust the maliciousness rate via score
        {best_entry, mut_hash, score} when score >= 0.8 ->
            %{mutations_hash: my_mut_hash} = Fabric.my_attestation_by_entryhash(best_entry.hash)
            if mut_hash != my_mut_hash do
                height = best_entry.header_unpacked.height
                slot = best_entry.header_unpacked.slot
                IO.puts "EMERGENCY: consensus chose entry #{Base58.encode(best_entry.hash)} for height/slot #{height}/#{slot}"
                IO.puts "but our mutations are #{Base58.encode(my_mut_hash)} while consensus is #{Base58.encode(mut_hash)}"
                IO.puts "EMERGENCY: consensus halted as state is out of sync with network"
                :erlang.halt()
            else
                Fabric.set_rooted_tip(best_entry.hash)
                proc_consensus()
            end
        _ -> nil
    end
  end

  def proc_entries() do
    cur_entry = Consensus.chain_tip_entry()
    height = cur_entry.header_unpacked.height
    next_entries = Fabric.entries_by_height(height+1)
    next_entries = Enum.filter(next_entries, fn(next_entry)->
      trainer_for_slot = Consensus.trainer_for_slot(Entry.epoch(next_entry), next_entry.header_unpacked.slot)
      in_slot = next_entry.header_unpacked.signer == trainer_for_slot
      in_slot and Entry.validate_next(cur_entry, next_entry) == %{error: :ok}
    end)
    |> Enum.sort_by(& &1.hash, :desc)
    case List.first(next_entries) do
      nil -> nil
      entry -> 
        %{error: :ok, attestation_packed: attestation_packed} = Consensus.apply_entry(entry)
        if attestation_packed do
          NodeGen.broadcast_attestation(attestation_packed)
        end
        proc_entries()
    end
  end

  def proc_if_my_slot() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()
    my_height = entry.header_unpacked.height
    highest_height = max(my_height, :persistent_term.get(:highest_height, 0))
    slot = entry.header_unpacked.slot
    next_epoch = div(my_height+1, 100_000)
    slot_trainer = Consensus.trainer_for_slot(next_epoch, slot + 1)
    peer_cnt = length(NodeGen.peers_online()) + 1

    cond do
      pk == slot_trainer and peer_cnt < Application.fetch_env!(:ama, :quorum) ->
        nil
      #TODO: confirm a valid entry with that height/hash otherwise they can lie to stall us
      pk == slot_trainer and highest_height - my_height > 0 ->
        IO.puts "🔴 my_height #{my_height} chain_height #{highest_height}"
        nil
      pk == slot_trainer ->
        #IO.puts "🔧 im in slot #{slot+1}, working.. *Click Clak*"
        next_entry = Consensus.produce_entry(slot + 1)
        #IO.puts "entry #{entry.header_unpacked.height} produced."
        NodeGen.broadcast_entry(next_entry)
        next_entry
      true ->
        nil
    end
  end
end
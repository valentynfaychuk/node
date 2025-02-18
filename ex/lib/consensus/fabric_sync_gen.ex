defmodule FabricSyncGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def hasQuorum() do
    :persistent_term.get({Net, :hasQuorum}, false)
  end

  def isSynced() do
    :persistent_term.get({Net, :isSynced}, nil)
  end

  def isInEpoch() do
    :persistent_term.get({Net, :isInEpoch}, false)
  end

  def highestTemporalHeight() do
    :persistent_term.get({Net, :highestTemporalHeight}, nil)
  end

  def isQuorumSynced() do
    hasQuorum() and isSynced() == :full
  end

  def isQuorumSyncedOffBy1() do
    hasQuorum() and isSynced()
  end

  def isQuorumIsInEpoch() do
    hasQuorum() and isInEpoch()
  end

  def init(state) do
    :persistent_term.put({Net, :hasQuorum}, false)
    :persistent_term.put({Net, :isSynced}, nil)
    :persistent_term.put({Net, :isInEpoch}, false)

    :erlang.send_after(1000, self(), :tick_quorum)
    :erlang.send_after(1000, self(), :tick_synced)
    :erlang.send_after(3000, self(), :tick)
    :erlang.send_after(3000, self(), :tick_missing_attestation)
    {:ok, state}
  end

  def handle_info(:tick_quorum, state) do
    quorum_cnt = Application.fetch_env!(:ama, :quorum)
    online_cnt = length(NodePeers.online())

    hasQ = hasQuorum()
    cond do
      online_cnt < quorum_cnt and hasQ -> :persistent_term.put({Net, :hasQuorum}, false)
      online_cnt >= quorum_cnt and !hasQ -> :persistent_term.put({Net, :hasQuorum}, true)
      true -> nil
    end

    :erlang.send_after(30, self(), :tick_quorum)
    {:noreply, state}
  end

  def handle_info(:tick_synced, state) do

    if hasQuorum() do
      tick_synced()
    end

    :erlang.send_after(30, self(), :tick_synced)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    ts_m = :os.system_time(1000)

    cond do
      isQuorumSyncedOffBy1() ->
        tick()
        :erlang.send_after(100, self(), :tick)
        
      hasQuorum() -> 
        tick()
        :erlang.send_after(300, self(), :tick)

      true -> :erlang.send_after(30, self(), :tick)
    end

    {:noreply, state}
  end

  def handle_info(:tick_missing_attestation, state) do
    cond do
      hasQuorum() ->
        tick_missing_attestation()
      true -> nil
    end
    :erlang.send_after(1600, self(), :tick_missing_attestation)
    {:noreply, state}
  end

  def tick_synced() do
    temporal = Consensus.chain_tip_entry()
    temporal_height = temporal.header_unpacked.height
    highest_peers = NodePeers.highest_height(%{sort: :temporal})
    highest_height = case List.first(highest_peers) do
      nil -> temporal_height
      [_, _, highest, _ | _ ] -> highest
    end

    old_highest = :persistent_term.get({Net, :highestTemporalHeight}, nil)
    highest_height = max(temporal_height, highest_height)
    if highest_height != old_highest do
      :persistent_term.put({Net, :highestTemporalHeight}, highest_height)
    end

    isS = isSynced()
    cond do
      highest_height - temporal_height == 0 and isS != :full -> :persistent_term.put({Net, :isSynced}, :full)
      highest_height - temporal_height == 1 and isS != :off_by_1 -> :persistent_term.put({Net, :isSynced}, :off_by_1)
      highest_height - temporal_height > 1 and isS -> :persistent_term.put({Net, :isSynced}, nil)
      true -> nil
    end

    isInEpoch = isInEpoch()
    epoch_highest = div(highest_height, 100_000)
    epoch_mine = div(temporal_height, 100_000)
    cond do
      epoch_highest == epoch_mine and !isInEpoch -> :persistent_term.put({Net, :isInEpoch}, true)
      epoch_highest != epoch_mine and isInEpoch -> :persistent_term.put({Net, :isInEpoch}, false)
      true -> nil
    end
  end

  def next_1000_holes_rooted(height, max_height, acc \\ []) do
    consens = Fabric.consensuses_by_height(height)
    cond do
      length(acc) >= 1000 -> acc
      height > max_height -> acc
      length(consens) == 0 -> next_1000_holes_rooted(height + 1, max_height, acc ++ [height])
      true -> next_1000_holes_rooted(height + 1, max_height, acc)
    end
  end

  def tick() do
    temporal = Consensus.chain_tip_entry()
    temporal_height = temporal.header_unpacked.height
    rooted = Fabric.rooted_tip_entry()
    rooted_height = rooted.header_unpacked.height

    highest_peers = NodePeers.highest_height(%{min_rooted: rooted_height, sort: :rooted})
    {highest_height, highest_consensus} = case List.first(highest_peers) do
      nil -> {temporal_height, rooted_height}
      [_, _, highest, consensus | _ ] -> {highest, consensus}
    end

    next1000_holes = FabricSyncGen.next_1000_holes_rooted(rooted_height+1, highest_height)
    len1000_holes = length(next1000_holes)

    #IO.inspect {highest_height, highest_consensus, rooted_height, len1000_holes}

    highest_peers = NodePeers.highest_height(%{min_temporal: temporal_height, sort: :temporal})
    {highest_height, _highest_consensus} = case List.first(highest_peers) do
      nil -> {temporal_height, rooted_height}
      [_, _, highest, consensus | _ ] -> {highest, consensus}
    end

    next1000_holes_temporal = FabricSyncGen.next_1000_holes_rooted(temporal_height+1, highest_height)
    len1000_holes_temporal = length(next1000_holes_temporal)

    #IO.inspect {highest_height, highest_consensus, len1000_holes}

    cond do
      !hasQuorum() -> nil

      len1000_holes > 0 and len1000_holes <= 3 ->
        if len1000_holes > 1 do
          IO.puts "Syncing #{len1000_holes} entries"
        end
        #IO.inspect {temporal_height, rooted_height, highest_peers}

        msg = NodeProto.catchup_tri(next1000_holes)
        peer_ips = Enum.shuffle(highest_peers) |> Enum.map(& hd(&1)) |> Enum.take(3)
        send(NodeGen, {:send_to_some, peer_ips, NodeProto.pack_message(msg)})

      len1000_holes_temporal > 0 and len1000_holes_temporal <= 3 ->
        if len1000_holes_temporal > 1 do
          IO.puts "Syncing #{len1000_holes_temporal} temporal entries"
        end
        #IO.inspect {temporal_height, rooted_height, highest_peers}

        msg = NodeProto.catchup_tri(next1000_holes_temporal)
        peer_ips = Enum.shuffle(highest_peers) |> Enum.map(& hd(&1)) |> Enum.take(3)
        send(NodeGen, {:send_to_some, peer_ips, NodeProto.pack_message(msg)})

      len1000_holes > 3 ->
        IO.puts "Syncing #{len1000_holes} entries"
        #IO.inspect next1000_holes

        #msg = NodeProto.catchup_tri(len1000_holes)
        #peer_ips = Enum.shuffle(highest_peers) |> Enum.map(& hd(&1)) |> Enum.take(2)
        #IO.inspect peer_ips
        #send(NodeGen, {:send_to_some, peer_ips, NodeProto.pack_message(msg)})

        next1000_holes = Enum.shuffle(next1000_holes)
        Enum.chunk_every(next1000_holes, 30)
        |> Enum.each(fn(chunk)->
          msg = NodeProto.catchup_tri(chunk)
          peer_ips = Enum.shuffle(highest_peers) |> Enum.map(& hd(&1)) |> Enum.take(3)
          send(NodeGen, {:send_to_some, peer_ips, NodeProto.pack_message(msg)})
        end)
        
      true -> nil
    end
  end

  #  FabricSyncGen.next_1000_holes_rooted_trainers 100_003, 100030
  def next_1000_holes_rooted_trainers(height, max_height) do
    next_1000_holes_rooted_trainers_1(height, max_height)
  end
  def next_1000_holes_rooted_trainers_1(height, max_height, acc \\ []) do
    consens = Fabric.consensuses_by_height(height)
    cond do
      length(acc) >= 1000 -> acc
      height > max_height -> acc
      true ->
        trainers = Consensus.trainers_for_height(height)
        height_add = Enum.reduce_while(consens, nil, fn(%{mask: mask}, acc)->
          best_score = BLS12AggSig.score(trainers, mask)
          if best_score < 1.0 do
            {:halt, height}
          else
            {:cont, nil}
          end
        end)
        if height_add do
          next_1000_holes_rooted_trainers_1(height + 1, max_height, acc ++ [height_add])
        else
          next_1000_holes_rooted_trainers_1(height + 1, max_height, acc)
        end
    end
  end

  def tick_missing_attestation() do
    temporal = Consensus.chain_tip_entry()
    temporal_height = temporal.header_unpacked.height
    rooted = Fabric.rooted_tip_entry()
    rooted_height = rooted.header_unpacked.height

    highest_peers = NodePeers.highest_height(%{min_rooted: rooted_height, sort: :rooted})
    {highest_height, highest_consensus} = case List.first(highest_peers) do
      nil -> {temporal_height, rooted_height}
      [_, _, highest, consensus | _ ] -> {highest, consensus}
    end

    delta = abs(highest_consensus - rooted_height)
    if delta > 16 do
      tick_missing_attestation_new()
    end

    next1000_holes = FabricSyncGen.next_1000_holes_rooted_trainers(rooted_height+1, highest_height)
    len1000_holes = length(next1000_holes)

    #IO.inspect {highest_height, highest_consensus, rooted_height, len1000_holes, next1000_holes}

    cond do
      #true -> nil
      !isQuorumSyncedOffBy1() -> nil

      len1000_holes > 0 ->
        if len1000_holes > 2 do
          IO.puts "Syncing #{len1000_holes} attestations"
        end
        #IO.inspect next1000_holes

        #next1000_holes = Enum.shuffle(next1000_holes) |> Enum.take(10)
        next1000_holes = Enum.take(next1000_holes, 10)
        hashes = Enum.map(next1000_holes, fn(height)->
          Fabric.entries_by_height(height)
        end)
        |> List.flatten()
        |> Enum.map(& &1.hash)
        #TODO: check missing
        #Consensus.missing_attestations()

        trainer_ips = NodePeers.for_height(rooted_height+1) |> Enum.map(& &1.ip)
        msg = NodeProto.catchup_attestation(hashes)
        send(NodeGen, {:send_to_some, trainer_ips, NodeProto.pack_message(msg)})
        
      true -> nil
    end
  end

  def tick_missing_attestation_new() do
    temporal = Consensus.chain_tip_entry()
    temporal_height = temporal.header_unpacked.height
    rooted = Fabric.rooted_tip_entry()
    rooted_height = rooted.header_unpacked.height

    highest_peers = NodePeers.highest_height(%{min_rooted: rooted_height, sort: :rooted})
    {highest_height, highest_consensus} = case List.first(highest_peers) do
      nil -> {temporal_height, rooted_height}
      [_, _, highest, consensus | _ ] -> {highest, consensus}
    end

    next1000_holes = FabricSyncGen.next_1000_holes_rooted_trainers(rooted_height+1, highest_height)
    len1000_holes = length(next1000_holes)

    #IO.inspect {highest_height, highest_consensus, rooted_height, len1000_holes, next1000_holes}

    cond do
      #true -> nil
      !hasQuorum() -> nil

      len1000_holes > 0 ->
        if len1000_holes > 2 do
          IO.puts "Syncing #{len1000_holes} attestations"
        end
        #IO.inspect next1000_holes

        peers = NodePeers.for_height(rooted_height+1)
        Enum.each(peers, fn(p)->
          next1000_holes = Enum.shuffle(next1000_holes)
          hashes = Enum.reduce_while(next1000_holes, [], fn(height, acc)->
            entry = Fabric.entries_by_height(height) |> Enum.random()
            hasSigned = Consensus.did_trainer_sign_consensus(p.pk, entry.hash)
            cond do
              length(acc) >= 29 ->
                #{:halt, acc}
                msg = NodeProto.catchup_attestation(acc)
                send(NodeGen, {:send_to_some, [p.ip], NodeProto.pack_message(msg)})
                {:cont, []}

              !hasSigned -> {:cont, acc ++ [entry.hash]}

              true -> {:cont, acc}
            end
          end)
          #msg = NodeProto.catchup_attestation(hashes)
          #send(NodeGen, {:send_to_some, [p.ip], NodeProto.pack_message(msg)})
        end)

        #next1000_holes = Enum.shuffle(next1000_holes) |> Enum.take(10)
        #next1000_holes = Enum.take(next1000_holes, 10)
        #hashes = Enum.map(next1000_holes, fn(height)->
        #  Fabric.entries_by_height(height)
        #end)
        #|> List.flatten()
        #|> Enum.map(& &1.hash)
        #|> Enum.each()
        #TODO: check missing
        #Consensus.missing_attestations()

        #Process.sleep(10)

        #trainer_ips = NodePeers.for_height(rooted_height+1) |> Enum.map(& &1.ip)
        #msg = NodeProto.catchup_attestation(hashes)
        #send(NodeGen, {:send_to_some, trainer_ips, NodeProto.pack_message(msg)})
        
      true -> nil
    end
  end
end

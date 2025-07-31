defmodule FabricSyncAttestGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def hasQuorum() do
    case :persistent_term.get({Net, :hasQuorum}, nil) do
      nil -> false
      atomic -> :atomics.get(atomic, 1) == 1
    end
  end

  def isSynced() do
    case :persistent_term.get({Net, :isSynced}, nil) do
      nil -> false
      atomic ->
        case :atomics.get(atomic, 1) do
          0 -> nil
          1 -> :off_by_1
          2 -> :full
        end
    end
  end

  def isInEpoch() do
    case :persistent_term.get({Net, :isInEpoch}, nil) do
      nil -> false
      atomic -> :atomics.get(atomic, 1) == 1
    end
  end

  def highestTemporalHeight() do
    case :persistent_term.get({Net, :highestTemporalHeight}, nil) do
      nil -> nil
      atomic -> :atomics.get(atomic, 1)
    end
  end

  def highestRootedHeight() do
    :persistent_term.get({Net, :highestRootedHeight}, nil)
  end

  def isQuorumSynced() do
    cond do
      !hasQuorum() -> false
      isSynced() != :full -> false
      Fabric.rooted_tip_height() < Consensus.chain_height() -> false
      true -> true
    end
  end

  def isQuorumSyncedOffBy1() do
    cond do
      !hasQuorum() -> false
      isSynced() in [:full, :off_by_1] -> true
      Fabric.rooted_tip_height() < (Consensus.chain_height() - 1) -> false
      isSynced() not in [:full, :off_by_1] -> false
      true -> true
    end
  end

  def isQuorumSyncedOffByX(cnt) do
    cond do
      !hasQuorum() -> false
      isSynced() in [:full, :off_by_1] -> true
      Fabric.rooted_tip_height() < (Consensus.chain_height() - cnt) -> false
      isSynced() not in [:full, :off_by_1] -> false
      true -> true
    end
  end

  def isQuorumIsInEpoch() do
    hasQuorum() and isInEpoch()
  end

  def init(state) do
    :persistent_term.put({Net, :hasQuorum}, :atomics.new(1, []))
    :persistent_term.put({Net, :isSynced}, :atomics.new(1, []))
    :persistent_term.put({Net, :isInEpoch}, :atomics.new(1, []))
    :persistent_term.put({Net, :highestTemporalHeight}, :atomics.new(1, []))


    :erlang.send_after(1000, self(), :tick_quorum)
    :erlang.send_after(1000, self(), :tick_synced)
    {:ok, state}
  end

  def handle_info(:tick_quorum, state) do
    quorum_cnt = Application.fetch_env!(:ama, :quorum)
    online_cnt = length(NodePeers.online())

    hasQ = hasQuorum()
    cond do
      online_cnt < quorum_cnt and hasQ -> :persistent_term.get({Net, :hasQuorum}) |> :atomics.put(1, 0)
      online_cnt >= quorum_cnt and !hasQ -> :persistent_term.get({Net, :hasQuorum}) |> :atomics.put(1, 1)
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

  def tick_synced() do
    temporal = Consensus.chain_tip_entry()
    temporal_height = temporal.header_unpacked.height

    highest_peers = NodePeers.highest_height(%{sort: :temporal})
    highest_height = case List.first(highest_peers) do
      nil -> temporal_height
      [_, _, highest, _ | _ ] -> highest
    end

    #highest_peers = NodePeers.highest_height_inchain(
    #  %{sort: :temporal, min_temporal: temporal_height-100, min_rooted: temporal_height-100})
    #highest_height = case List.first(highest_peers) do
    #  nil -> temporal_height
    #  highest -> highest
    #end

    old_highest = highestTemporalHeight()
    highest_height = max(temporal_height, highest_height)
    if highest_height != old_highest do
      :persistent_term.get({Net, :highestTemporalHeight}) |> :atomics.put(1, highest_height)
    end

    isS = isSynced()
    cond do
      highest_height - temporal_height == 0 and isS != :full -> :persistent_term.get({Net, :isSynced}) |> :atomics.put(1, 2)
      highest_height - temporal_height == 1 and isS != :off_by_1 -> :persistent_term.get({Net, :isSynced}) |> :atomics.put(1, 1)
      highest_height - temporal_height > 1 and isS -> :persistent_term.get({Net, :isSynced}) |> :atomics.put(1, 0)
      true -> nil
    end

    isInEpoch = isInEpoch()
    epoch_highest = div(highest_height, 100_000)
    epoch_mine = div(temporal_height, 100_000)
    cond do
      epoch_highest == epoch_mine and !isInEpoch -> :persistent_term.get({Net, :isInEpoch}) |> :atomics.put(1, 1)
      epoch_highest != epoch_mine and isInEpoch -> :persistent_term.get({Net, :isInEpoch}) |> :atomics.put(1, 0)
      true -> nil
    end
  end
end

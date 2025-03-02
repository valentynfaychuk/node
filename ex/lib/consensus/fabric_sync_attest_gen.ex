defmodule FabricSyncAttestGen do
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

  def highestRootedHeight() do
    :persistent_term.get({Net, :highestRootedHeight}, nil)
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
end

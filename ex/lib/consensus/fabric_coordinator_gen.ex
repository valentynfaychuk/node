defmodule FabricCoordinatorGen do
  use GenServer

  def isSyncing() do
    case :persistent_term.get(FabricCoordinatorSyncing, nil) do
      nil -> false
      atomic -> :atomics.get(atomic, 1) == 1
    end
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :persistent_term.put(FabricCoordinatorSyncing, :atomics.new(1, []))

    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def calc_syncing() do
    isSyncn = isSyncing()
    {_, num} = Process.info(self(), :message_queue_len)
    cond do
      num >= 10 and !isSyncn -> :persistent_term.get(FabricCoordinatorSyncing) |> :atomics.put(1, 1)
      num < 10 and isSyncn -> :persistent_term.get(FabricCoordinatorSyncing) |> :atomics.put(1, 0)
      true -> nil
    end
  end

  def handle_info(:tick, state) do
    calc_syncing()
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def handle_info({:validate_consensus, consensus}, state) do
    calc_syncing()
    :erlang.spawn(fn()->
      case Consensus.validate_vs_chain(consensus) do
        %{error: :ok, consensus: consensus} ->
          send(FabricCoordinatorGen, {:insert_consensus, consensus})
        _ -> nil
      end
    end)
    {:noreply, state}
  end

  def handle_info({:insert_consensus, consensus}, state) do
    calc_syncing()
    Fabric.insert_consensus(consensus)
    {:noreply, state}
  end

  def handle_info({:add_attestation, attestation}, state) do
    calc_syncing()

    Fabric.aggregate_attestation(attestation)

    #proc cached attestations
    ts_m = :os.system_time(1000)
    cached = :ets.select(AttestationCache, [{{{attestation.entry_hash, :_}, {:"$1", :_}}, [], [:"$1"]}])
    Enum.each(cached, fn(attestation)->
      Fabric.aggregate_attestation(attestation)
    end)
    if cached != [] do
      deleted = :ets.select_delete(AttestationCache, [{{{attestation.entry_hash, :_}, :_}, [], [true]}])
      #IO.inspect {:os.system_time(1000) - ts_m, length(cached), deleted, attestation.entry_hash |> Base58.encode()}
    end

    #clear stales
    case :ets.first_lookup(AttestationCache) do
      :'$end_of_table' -> nil
      {key, [{_, {_, ts_m_old}}]} ->
        delta = ts_m - ts_m_old
        if delta >= 10_000 do
          :ets.delete(AttestationCache, key)
        end
    end

    {:noreply, state}
  end
end

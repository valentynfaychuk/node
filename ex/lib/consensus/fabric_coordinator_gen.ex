defmodule FabricCoordinatorGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def precalc_sols(entry) do
    :erlang.spawn(fn()->
      Enum.each(entry.txs, fn(tx_packed)->
        isSol = String.contains?(tx_packed, "submit_sol")
        if isSol do
          txu = TX.unpack(tx_packed)
          [%{args: [sol]}] = txu.tx.actions
          isVerified = :ets.lookup_element(SOLVerifyCache, sol, 2, nil)
          if !isVerified do
            :ets.insert(SOLVerifyCache, {sol, :inprogress})
            valid = BIC.Sol.verify(sol)
            if valid do
              :ets.insert(SOLVerifyCache, {sol, :valid})
            else
              :ets.insert(SOLVerifyCache, {sol, :invalid})
            end
          end
        end
      end)
    end)
  end

  def handle_info({:insert_entry, entry, seen_time}, state) do
    Fabric.insert_entry(entry, seen_time)
    precalc_sols(entry)
    {:noreply, state}
  end

  def handle_info({:validate_consensus, consensus}, state) do
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
    Fabric.insert_consensus(consensus)
    {:noreply, state}
  end

  def handle_info({:add_attestation, attestation}, state) do
    Fabric.aggregate_attestation(attestation)
    {:noreply, state}
  end
end

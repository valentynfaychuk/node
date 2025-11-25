defmodule FabricEventGen do
  use GenServer

  def event_rooted(entry, mut_hash) do
    send(FabricEventGen, {:entry_rooted, entry, mut_hash})
  end

  def event_applied(entry, mut_hash, m, l) do
    send(FabricEventGen, {:entry, entry, mut_hash, m, l})
  end

  def broadcast(update) do
      pids = :pg.get_members(PGWSRPC)
      Enum.each(pids, & send(&1, update))
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def tick(state) do
    #IO.inspect "tick"
    {:message_queue_len, n} = :erlang.process_info(self(), :message_queue_len)
    n > 100 && purge_pending()
    state
  end

  defp purge_pending do
    receive do
      _other -> purge_pending()
    after 0 ->
      :ok
    end
  end

  def handle_info(:tick, state) do
    state = if true do tick(state) else state end
    :erlang.send_after(100, self(), :tick)
    {:noreply, state}
  end

  def handle_info({:entry, entry, muts_hash, muts, logs}, state) do
    height = Entry.height(entry)
    if logs != [] do
      #IO.inspect {height, logs, muts}
    end

    #IO.inspect API.Chain.format_entry_for_client(entry), limit: 11111
    entry_b58 = API.Chain.format_entry_for_client(entry)
    txs = Enum.map(entry.txs, fn(txu)->
      API.TX.format_tx_for_client(txu)
    end)
    broadcast({:update_stats_entry_tx, API.Chain.stats(), entry_b58, txs})

    {:noreply, state}
  end

  def handle_info({:entry_rooted, entry, mut_hash}, state) do
    {:noreply, state}
  end
end

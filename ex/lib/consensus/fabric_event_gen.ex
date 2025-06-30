defmodule FabricEventGen do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def tick(state) do
    #IO.inspect "tick"
    state
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
    {:noreply, state}
  end
end

defmodule LoggerGen do
  use GenServer

  def start() do
    send(__MODULE__, :start)
  end

  def stop() do
    send(__MODULE__, :stop)
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{enabled: true}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    state = if state[:enabled] do tick(state) else state end
    :erlang.send_after(6000, self(), :tick)
    {:noreply, state}
  end

  def handle_info(:start, state) do
    state = Map.put(state, :enabled, true)
    {:noreply, state}
  end

  def handle_info(:stop, state) do
    state = Map.put(state, :enabled, false)
    {:noreply, state}
  end

  def tick(state) do
    height = Blockchain.height()
    highest_height = :persistent_term.get(:highest_height, 0)
    highest_height = max(height, highest_height)
    hash = Blockchain.hash()
    txpool_size = :ets.info(TXPool, :size)
    peers_size = :ets.info(NODEPeers, :size)

    trainer_pk_b58 = Application.fetch_env!(:ama, :trainer_pk_b58)
    coins = BIC.Coin.from_flat(BIC.Coin.balance(trainer_pk_b58))
    IO.puts "⛓️: #{height} / #{highest_height} | T: #{txpool_size} P: #{peers_size} | #{trainer_pk_b58} 🪙 #{coins}"

    state
  end
end
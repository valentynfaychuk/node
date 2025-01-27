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
    state = if state[:enabled] do try do tick(state) catch _,_ -> state end else state end
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
    entry_rooted = Fabric.rooted_tip_entry()
    rooted_height = entry_rooted.header_unpacked.height

    entry = Consensus.chain_tip_entry()
    entry = Entry.unpack(entry)
    height = entry.header_unpacked.height
    slot = entry.header_unpacked.slot
    highest_height = :persistent_term.get(:highest_height, 0)
    highest_height = max(height, highest_height)
    txpool_size = :ets.info(TXPool, :size)
    peer_cnt = length(NodeGen.peers_online()) + 1

    pk = Application.fetch_env!(:ama, :trainer_pk)
    coins = Consensus.chain_balance(pk)
    quorum = Application.fetch_env!(:ama, :quorum)

    trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))

    #Moneybag mean the money in my bag
    #Moneybag mean the money in the bag
    #Moneyround mean i roll wit da money
    isTrainer = if pk in trainers do "💰" else "🪙" end

    if peer_cnt < quorum do
      IO.puts "⛓️  #{height} / #{highest_height} R: #{height-rooted_height} S: #{slot} | T: #{txpool_size} P: #{peer_cnt} 🔴 QUORUM REQUIRES #{quorum} PEERS"
    else
      IO.puts "⛓️  #{height} / #{highest_height} R: #{height-rooted_height} S: #{slot} | T: #{txpool_size} P: #{peer_cnt} | #{Base58.encode(pk)} #{isTrainer} #{coins}"
    end

    state
  end
end
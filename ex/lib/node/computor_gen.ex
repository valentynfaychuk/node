defmodule ComputorGen do
  use GenServer

  def start(type \\ nil) do
    send(__MODULE__, {:start, type})
  end

  def stop() do
    send(__MODULE__, :stop)
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{enabled: false}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    peer_cnt = length(NodeGen.peers_online()) + 1

    my_height = Consensus.chain_height()
    highest_height = max(my_height, :persistent_term.get(:highest_height, 0))

    state = cond do
      !state[:enabled] -> state
      peer_cnt < Application.fetch_env!(:ama, :quorum) ->
        IO.puts "🔴 cannot compute: no quorum"
        state
      highest_height - my_height > 30 ->
        IO.puts "🔴 out_of_sync: my_height #{my_height} peer_height #{highest_height}"
        state
      true -> tick(state)
    end
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def handle_info({:start, type}, state) do
    state = Map.put(state, :enabled, true)
    state = Map.put(state, :type, type)
    {:noreply, state}
  end

  def handle_info(:stop, state) do
    state = Map.put(state, :enabled, false)
    {:noreply, state}
  end

  def tick(state) do
    IO.puts "computor running #{DateTime.utc_now()}"
    pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
    pop_raw = Application.fetch_env!(:ama, :trainer_pop_raw)

    coins = Consensus.chain_balance(pk_raw)
    epoch = Consensus.chain_epoch()
    height = Consensus.chain_height()
    hasExecCoins = coins >= BIC.Coin.to_flat(1)
    sol = if state.type != :trainer do
        UPOW.compute_for(epoch, EntryGenesis.signer(), EntryGenesis.pop(), pk_raw)
    else
        UPOW.compute_for(epoch, pk_raw, pop_raw, pk_raw)
    end
    cond do
        !sol -> nil
        state.type == :trainer and !hasExecCoins ->
            IO.puts "🔢 tensor matmul complete! broadcasting sol.."
            NodeGen.broadcast_sol(sol)
        state.type == nil ->
            IO.puts "🔢 tensor matmul complete! broadcasting sol.."
            NodeGen.broadcast_sol(sol)
        true ->
            sk_raw = Application.fetch_env!(:ama, :trainer_sk_raw)
            packed_tx = TX.build_transaction(sk_raw, height, "Epoch", "submit_sol", [Base58.encode(sol)])
            %{hash: hash} = TX.unwrap(packed_tx)
            IO.puts "🔢 tensor matmul complete! tx #{hash}"

            TXPool.insert(packed_tx)
            NodeGen.broadcast_tx(packed_tx)
    end
    state
  end 
end
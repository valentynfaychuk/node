defmodule ComputorGen do
  use GenServer

  def start() do
    send(__MODULE__, :start)
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
    state = if state[:enabled] do tick(state) else state end
    :erlang.send_after(1000, self(), :tick)
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
    IO.puts "computor running #{DateTime.utc_now()}"
    pk_raw = Application.fetch_env!(:ama, :trainer_pk)
    pk_b58 = Application.fetch_env!(:ama, :trainer_pk_b58)

    coins = BIC.Coin.balance(Base58.encode(pk_raw))
    hasExecCoins = coins >= BIC.Coin.to_flat(1)
    sol = if !hasExecCoins do
        UPOW.compute_for(Base58.decode("4MXG4qor6TRTX9Wuu9TEku7ivBtDooNL55vtu3HcvoQH"), pk_raw)
    else
        UPOW.compute_for(pk_raw, pk_raw)
    end
    cond do
        !sol -> nil
        !hasExecCoins ->
            IO.puts "🔢 tensor matmul complete! broadcasting sol.."
            NodeGen.send_sol(sol)
        true ->
            sk_raw = Application.fetch_env!(:ama, :trainer_sk)
            packed_tx = TX.build_transaction(sk_raw, Blockchain.height(), "Trainer", "submit_sol", [Base58.encode(sol)])
            %{hash: hash} = TX.unwrap(packed_tx)
            IO.puts "🔢 tensor matmul complete! tx #{hash}"

            TXPool.insert(packed_tx)
            NodeGen.send_txpool(packed_tx)
    end
    state
  end 
end
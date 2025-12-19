defmodule DB.Entry.Hashbuilder do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    case RocksDB.get("filter_hashes_end_hash", DB.API.db_handle(%{}, :sysconf, %{})) do
      nil ->
        IO.inspect "starting hashfilter builder"
        RocksDB.put("filter_hashes_end_hash", DB.Chain.tip(), DB.API.db_handle(%{}, :sysconf, %{}))
      _ -> nil
    end

    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    if RocksDB.get_cf_size(:tx_filter) >= 60 do
      clear()
    end
    tick()
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def clear() do
    IO.puts "clearing stale hashfilter"
    RocksDB.delete_range_cf_call(:tx_filter, true)
    RocksDB.delete("filter_hashes_rebuilt_up_to", DB.API.db_handle(%{}, :sysconf, %{}))
    RocksDB.put("filter_hashes_end_hash", DB.Chain.tip(), DB.API.db_handle(%{}, :sysconf, %{}))
  end

  def tick() do
    rebuilt_up_to = RocksDB.get("filter_hashes_rebuilt_up_to", DB.API.db_handle(%{}, :sysconf, %{})) || EntryGenesis.get().hash
    rebuilt_up_to_height = DB.Entry.by_hash(rebuilt_up_to).header.height
    rebuilt_end = RocksDB.get("filter_hashes_end_hash", DB.API.db_handle(%{}, :sysconf, %{}))
    rebuilt_end_height = DB.Entry.by_hash(rebuilt_end).header.height
    if rebuilt_up_to_height <= rebuilt_end_height do
      Enum.each(0..100_000, fn(_)-> DB.Entry.build_filter_hashes() end)
    end
  end
end

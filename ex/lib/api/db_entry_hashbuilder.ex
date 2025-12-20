defmodule DB.Entry.Hashbuilder do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start() do :persistent_term.put(HashBuilder, true) end
  def start_counter(to_height) do :persistent_term.put(HashBuilderCounter, to_height) end
  def stop() do :persistent_term.put(HashBuilder, false) end
  def stop_counter() do :persistent_term.put(HashBuilderCounter, nil) end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    :persistent_term.get(HashBuilder, false) && tick()
    :persistent_term.get(HashBuilderCounter, nil) && tick_count()
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def clear_all() do
    IO.puts "clearing stale hashfilter"
    RocksDB.delete_range_cf_call(:tx_filter, false)
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

  def tick_count() do
    count_up_to = RocksDB.get("txs_count_up_to", DB.API.db_handle(%{}, :sysconf, %{})) || EntryGenesis.get().hash
    count_up_to_height = DB.Entry.by_hash(count_up_to).header.height
    if count_up_to_height < :persistent_term.get(HashBuilderCounter) do
      Enum.each(0..100_000, fn(_)-> count_txs() end)
    end
  end

  def count_txs() do
    count_up_to = RocksDB.get("txs_count_up_to", DB.API.db_handle(%{}, :sysconf, %{})) || EntryGenesis.get().hash
    entry = DB.Entry.by_hash(count_up_to)
    if entry.header.height >= :persistent_term.get(HashBuilderCounter) do
      throw %{error: :count_txs_finished, height: entry.header.height}
    end

    if rem(entry.header.height, 10_000) == 0 do
      IO.inspect {:count_up_to, entry.header.height}
    end

    old_cnt = RocksDB.get("tx_count_historic", DB.API.db_handle(%{}, :sysconf, %{})) || "0"
    new_cnt = :erlang.binary_to_integer(old_cnt) + length(entry.txs)
    RocksDB.put("tx_count_historic", :erlang.integer_to_binary(new_cnt), DB.API.db_handle(%{}, :sysconf, %{}))

    n = DB.Entry.next(count_up_to)
    if n do
      RocksDB.put("txs_count_up_to", n, DB.API.db_handle(%{}, :sysconf, %{}))
    end
  end
end

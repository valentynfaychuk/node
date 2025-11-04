defmodule FabricCleaner do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(1000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    check_and_clean_finality()
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def check_and_clean_finality() do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    finality_clean_next_epoch = RocksDB.get("finality_clean_next_epoch", %{db: db, cf: cf.sysconf, term: true}) || 0
    epoch = DB.Chain.epoch()
    if finality_clean_next_epoch < (epoch-1) do
      clean_finality(finality_clean_next_epoch)
    end
  end

  def clean_finality(epoch) do
    IO.inspect {:clean_finality_epoch, epoch}
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    start_height = epoch * 100_000
    end_height = start_height + 99_999

    stream = Task.async_stream(0..9, fn(idx)->
      start_index = start_height+idx*10_000
      clean_muts_rev(epoch, start_index, start_index+9_999)
    end, [{:timeout, :infinity}])
    Enum.each(stream, & &1)

    RocksDB.put("finality_clean_next_epoch", epoch+1, %{db: db, cf: cf.sysconf, term: true})
  end

  def clean_muts_rev(epoch, start, fin) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    rtx = RocksDB.transaction(db)
    Enum.each(start..fin, fn(height)->
      if rem(height, 1000) == 0 do
        IO.inspect {:clean_muts_rev, height}
      end
      entries = DB.Chain.entries_by_height(height)
      Enum.each(entries, fn %{hash: hash} ->
        RocksDB.delete(hash, %{rtx: rtx, cf: cf.muts_rev})
      end)
    end)
    :ok = RocksDB.transaction_commit(rtx)
  end
end

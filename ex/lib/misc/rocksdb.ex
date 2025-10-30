defmodule RocksDB do
    def get(key, opts) do
        db = opts[:db]
        cf = opts[:cf]
        rtx = opts[:rtx]
        cond do
            !!rtx and !!cf -> RDB.transaction_get_cf(rtx, cf, key)
            !!rtx -> RDB.transaction_get(rtx, key)
            !!db and !!cf -> RDB.get_cf(cf, key)
            !!db -> RDB.get(db, key)
        end
        |> case do
            {:ok, nil} -> nil
            {:ok, value} ->
                cond do
                    opts[:term] -> :erlang.binary_to_term(value)
                    opts[:to_integer] -> :erlang.binary_to_integer(value)
                    true -> value
                end
        end
    end

    def get_next(prefix, key, opts) do
        {:ok, it} = iterator(opts)

        seek_string = prefix <> key
        seek_res = RDB.iterator_move(it, {:seek, seek_string})
        seek_res = case seek_res do
            {:ok, ^seek_string, _value} -> RDB.iterator_move(it, :next)
            other -> other
        end

        offset = opts[:offset] || 0
        seek_res = if offset <= 0 do seek_res else
            Enum.reduce(1..offset, seek_res, fn(_, _)->
                RDB.iterator_move(it, :next)
            end)
        end

        case seek_res do
            {:ok, <<^prefix::binary, next_key::binary>>, value} ->
                value = if opts[:term] do :erlang.binary_to_term(value) else value end
                {next_key, value}
            _ -> {nil, nil}
        end
    end

    def get_prev(prefix, key, opts) do
        {:ok, it} = iterator(opts)

        seek_string = prefix <> key
        seek_res = RDB.iterator_move(it, {:seek_for_prev, "#{prefix}#{key}"})
        seek_res = case seek_res do
            {:ok, ^seek_string, _value} -> RDB.iterator_move(it, :prev)
            other -> other
        end

        offset = opts[:offset] || 0
        seek_res = if offset <= 0 do seek_res else
            Enum.reduce(1..offset, seek_res, fn(_, _)->
                RDB.iterator_move(it, :prev)
            end)
        end

        case seek_res do
            {:ok, <<^prefix::binary, prev_key::binary>>, value} ->
                value = if opts[:term] do :erlang.binary_to_term(value) else value end
                {prev_key, value}
            _ -> {nil, nil}
        end
    end

    def get_prev_or_first(prefix, key, opts) do
        {:ok, it} = iterator(opts)
        res = RDB.iterator_move(it, {:seek_for_prev, "#{prefix}#{key}"})
        case res do
            {:ok, <<^prefix::binary, prev_key::binary>>, value} ->
                value = if opts[:term] do :erlang.binary_to_term(value) else value end
                {prev_key, value}
            _ -> {nil, nil}
        end
    end

    def get_bit(key, bit_idx, opts) do
      db = opts[:db]
      cf = opts[:cf]
      rtx = opts[:rtx]
      cond do
          !!rtx and !!cf -> RDB.transaction_get_cf(rtx, cf, key)
          !!rtx -> RDB.transaction_get(rtx, key)
          !!db and !!cf -> RDB.get_cf(cf, key)
          !!db -> RDB.get(db, key)
      end
      |> case do
          {:ok, nil} -> nil
          {:ok, value} ->
            << left::size(bit_idx), bit::size(1), _::bitstring >> = value
            bit
      end
    end

    def put(key, value, opts) do
        db = opts[:db]
        cf = opts[:cf]
        rtx = opts[:rtx]
        value = if opts[:term] do :erlang.term_to_binary(value, [:deterministic]) else value end
        value = if opts[:to_integer] do :erlang.integer_to_binary(value) else value end
        cond do
            !!rtx and !!cf -> :ok = RDB.transaction_put_cf(rtx, cf, key, value)
            !!rtx -> :ok = RDB.transaction_put(rtx, key, value)
            !!db and !!cf -> RDB.put_cf(cf, key, value)
            !!db -> RDB.put(db, key, value)
        end
    end

    def delete(key, opts) do
        db = opts[:db]
        cf = opts[:cf]
        rtx = opts[:rtx]
        cond do
            !!rtx and !!cf -> RDB.transaction_delete_cf(rtx, cf, key)
            !!rtx -> RDB.transaction_delete(rtx, key)
            !!db and !!cf -> RDB.delete_cf(cf, key)
            !!db -> RDB.delete(db, key)
        end
    end

    def get_prefix(prefix, opts) do
        {:ok, it} = iterator(opts)
        res = RDB.iterator_move(it, {:seek, prefix})
        get_prefix_1(prefix, it, res, opts, [])
    end
    defp get_prefix_1(prefix, it, res, opts, acc) do
        case res do
            {:ok, <<^prefix::binary, key::binary>>, value} ->
                value = if opts[:term] do :erlang.binary_to_term(value) else value end
                value = if opts[:to_integer] do :erlang.binary_to_integer(value) else value end
                res = RDB.iterator_move(it, :next)
                get_prefix_1(prefix, it, res, opts, acc ++ [{key, value}])
            {:error, :invalid_iterator} -> acc
            _ -> acc
        end
    end

    defp iterator(opts) do
        db = opts[:db]
        cf = opts[:cf]
        rtx = opts[:rtx]
        cond do
            !!rtx and !!cf -> RDB.transaction_iterator_cf(rtx, cf)
            !!rtx -> RDB.transaction_iterator(rtx)
            !!db and !!cf -> RDB.iterator_cf(cf)
            !!db -> RDB.iterator(db)
        end
    end

    def transaction(db) do
      {:ok, rtx} = RDB.transaction(db)
      rtx
    end

    def transaction_commit(rtx) do
      :ok = RDB.transaction_commit(rtx)
    end

    def dump(db_ref, cf) do
        {:ok, it} = RDB.iterator_cf(db_ref, cf)
        res = RDB.iterator_move(it, :first)
        dump_1(it, res)
    end
    defp dump_1(it, res) do
        case res do
            {:ok, key, value} ->
                IO.inspect {key, value}
                res = RDB.iterator_move(it, :next)
                dump_1(it, res)
            {:error, :invalid_iterator} -> nil
            _ -> nil
        end
    end

    def checkpoint(db_ref, path) do
        RDB.checkpoint(db_ref, path)
    end

    def snapshot(output_path) do
        %{args: args} = :persistent_term.get({:flatkv_fd, Fabric})
        File.mkdir_p!(output_path)
        {"", 0} = System.shell("cp --reflink=always #{args.path}/#{Fabric} #{output_path}", [{:stderr_to_stdout, true}])
    end

    def restore_from_snapshot(path) do
    end

    def flush_all(cfs) do
        Enum.each(Map.values(cfs), fn(cf)->
            RDB.flush_cf(cf)
        end)
    end

    def flush_wal(db) do
        RDB.flush_wal(db, true)
    end

    def compact_all(cfs) do
        Enum.each(Map.values(cfs), fn(cf)->
            RDB.compact_range_cf_all(cf)
        end)
    end

    def get_lru(db) do
      {:ok, cap} = :rocksdb.get_property(db, "rocksdb.block-cache-capacity")
      {:ok, used} = :rocksdb.get_property(db, "rocksdb.block-cache-usage")
      {:erlang.binary_to_integer(used), :erlang.binary_to_integer(cap)}
    end
end

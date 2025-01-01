defmodule BIC.KV do
    #TODO: add CoW tables

    def kv_create(table) do
        try do
        :ets.new(table, [:ordered_set, :named_table, :public,
            {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
        catch
            e,r -> nil
        end
    end

    def kv_merge(table, key, value \\ %{}) do
        exists = :ets.member(table, key)
        old_value = :ets.lookup_element(table, key, 2, %{})
        new_value = merge_nested(old_value, value)
        
        key_jcs = if !is_tuple(key) do key else
            :erlang.tuple_to_list(key)
        end
        mut = JCS.serialize(%{op: :merge, table: table, key: key_jcs, value: value})
        Process.put(:mutations, Process.get(:mutations, <<>>) <> <<byte_size(mut)::32-little, mut::binary>>)

        if exists do
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "insert", table: table, key: key, value: old_value}])
        else
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "delete", table: table, key: key}])
        end

        :ets.insert(table, {key, new_value})
    end

    def kv_increment(table, key, value, default \\ 0) do
        exists = :ets.member(table, key)
        key_jcs = if !is_tuple(key) do key else
            :erlang.tuple_to_list(key)
        end
        mut = JCS.serialize(%{op: :increment, table: table, key: key_jcs, value: value, default: default})
        Process.put(:mutations, Process.get(:mutations, <<>>) <> <<byte_size(mut)::32-little, mut::binary>>)

        if exists do
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "increment", table: table, key: key, value: -1*value, default: default}])
        else
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "delete", table: table, key: key}])
        end

        :ets.update_counter(table, key, {2, value}, {key, default})
    end

    def kv_get(table, key) do
        :ets.lookup_element(table, key, 2, nil)
    end

    def kv_keys(table) do
        :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
    end

    def kv_get(table) do
        :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
    end

    def kv_exists(table, key) do
        :ets.member(table, key)
    end

    def kv_delete(table, key) do
        key_jcs = if !is_tuple(key) do key else
            :erlang.tuple_to_list(key)
        end
        mut = JCS.serialize(%{op: :delete, table: table, key: key_jcs})
        Process.put(:mutations, Process.get(:mutations, <<>>) <> <<byte_size(mut)::32-little, mut::binary>>)

        old_value = :ets.lookup_element(table, key, 2, %{})
        Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "insert", table: table, key: key, value: old_value}])

        :ets.delete(table, key)
    end

    def kv_delete_match(table, pattern) do
        pattern_jcs = if !is_tuple(pattern) do pattern else
            :erlang.tuple_to_list(pattern)
        end
        mut = JCS.serialize(%{op: :delete_match, table: table, pattern: pattern_jcs})
        Process.put(:mutations, Process.get(:mutations, <<>>) <> <<byte_size(mut)::32-little, mut::binary>>)

        old_objects = :ets.match_object(table, pattern)
        Enum.each(old_objects, fn({key, v})->
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "insert", table: table, key: key, value: v}])
        end)

        :ets.match_delete(table, pattern)
    end

    def kv_clear(table) do
        mut = JCS.serialize(%{op: :delete_all, table: table})
        Process.put(:mutations, Process.get(:mutations, <<>>) <> <<byte_size(mut)::32-little, mut::binary>>)

        old_objects = :ets.tab2list(table)
        Enum.each(old_objects, fn({key, v})->
            Process.put(:mutations_reverse, Process.get(:mutations_reverse, []) ++ [%{op: "insert", table: table, key: key, value: v}])
        end)

        :ets.delete_all_objects(table)
    end

    def merge_nested(left, right) do
        Map.merge(left, right, &merge_nested_resolve/3)
    end
    defp merge_nested_resolve(_, left, right) do
        case {is_map(left), is_map(right)} do
            {true, true} -> merge_nested(left, right)
            _ -> right
        end
    end
end
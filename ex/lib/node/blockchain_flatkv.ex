defmodule BlockchainFlatKV do
    def load_blockchain() do
        workdir = Application.fetch_env!(:ama, :work_folder)
        args = %{workdir: workdir}

        File.mkdir_p!(Path.join(args.workdir, "blockchain/"))
        
        :ets.new(Blockchain, [:ordered_set, :named_table, :public,
          {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
        :ets.new(TXInChain, [:ordered_set, :named_table, :public,
          {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])

        filepath_blockchain = Path.join(args.workdir, "blockchain/blockchain.flatkv")
        {:ok, fd_blockchain} = :file.open(filepath_blockchain, [:read, :write, :append, :binary, {:read_ahead, 1048576}, :sync])

        load_blocks_and_calculate_state(fd_blockchain, 0)

        :persistent_term.put({:flatkv, Blockchain}, %{fd: fd_blockchain, args: args})
    end

    def save_block(header_encoded) do
        %{fd: fd_blockchain} = :persistent_term.get({:flatkv, Blockchain})
        :ok = :file.write(fd_blockchain, <<byte_size(header_encoded)::32-little, header_encoded::binary>>)
    end

    def load_blocks_and_calculate_state(fd_blockchain, height) do
        case :file.read(fd_blockchain,4) do
            :eof -> :ok
            {:ok, <<size::32-little>>} ->
                {:ok, block_packed} = :file.read(fd_blockchain, size)
                bu = Block.unwrap(block_packed)
                
                if bu.block.height != height, do: throw %{error: :blockchain_missing_block, height: height}

                %{error: err} = Block.validate(block_packed)
                if err != :ok, do: throw(err)
                
                Blockchain.insert_block(block_packed, true)

                load_blocks_and_calculate_state(fd_blockchain, height + 1)
        end
    end

    def locally_apply_state_mutation(mutation) do
        m = mutation

        table = if is_binary(m.table), do: String.to_existing_atom(m.table), else: m.table
        if !Process.get({:exists, table}) do
            :ets.new(table, [:ordered_set, :named_table, :public,
              {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
            Process.put({:exists, table}, true)
        end
        key = if !is_list(m.key) do m.key else :erlang.list_to_tuple(m.key) end
        case m.op do
            "merge" -> 
                old_map = :ets.lookup_element(table, key, 2, %{})
                :ets.insert(table, {key, BIC.KV.merge_nested(old_map, m.value)})
            "insert" -> :ets.insert(table, {key, m.value})
            "increment" -> :ets.update_counter(table, key, {2, m.value}, {key, m.default})
            "delete" -> :ets.delete(table, key)
            "delete_match" -> :ets.match_delete(table, m.pattern)
            "delete_all" -> :ets.delete_all_objects(table)
        end
    end

    def snapshot(output_path) do
        %{args: args} = :persistent_term.get({:flatkv_fd, Blockchain})
        File.mkdir_p!(output_path)
        {"", 0} = System.shell("cp --reflink=always #{args.path}/#{Blockchain} #{output_path}", [{:stderr_to_stdout, true}])
    end

    def restore_from_snapshot(path) do
    end
end
defmodule Consensus do
    def unpack(consensus_packed) when is_binary(consensus_packed) do
        :erlang.binary_to_term(consensus_packed, [:safe])
        |> unpack()
    end
    def unpack(consensus_packed) when is_map(consensus_packed) do
        consensus_packed
        |> Map.take([:entry_hash, :mutations_hash, :mask, :aggsig])
    end

    def pack(consensus_packed) when is_binary(consensus_packed) do consensus_packed end
    def pack(consensus_packed) do
        consensus_packed
        |> Map.take([:entry_hash, :mutations_hash, :mask, :aggsig])
        |> :erlang.term_to_binary([:deterministic])
    end

    def validate_vs_chain(c) do
        try do
        to_sign = <<c.entry_hash::binary, c.mutations_hash::binary>>

        entry = DB.Chain.entry(c.entry_hash)
        if !entry, do: throw(%{error: :invalid_entry})
        if entry.header_unpacked.height > DB.Chain.height(), do: throw(%{error: :too_far_in_future})

        #TODO: race here if entry is not proced
        trainers = DB.Chain.validators_for_height(Entry.height(entry))
        score = BLS12AggSig.score(trainers, c.mask)

        trainers_signed = BLS12AggSig.unmask_trainers(trainers, c.mask)
        aggpk = BlsEx.aggregate_public_keys!(trainers_signed)
        if !BlsEx.verify?(aggpk, c.aggsig, to_sign, BLS12AggSig.dst_att()), do: throw(%{error: :invalid_signature})

        c = Map.put(c, :score, score)
        %{error: :ok, consensus: c}
        catch
            :throw,r -> r
            e,r -> IO.inspect {Consensus, :validate, e, r, __STACKTRACE__}; %{error: :unknown}
        end
    end

    def chain_rewind(target_hash) do
        in_chain = Consensus.is_in_chain(target_hash)
        cond do
            !in_chain -> false
            true ->
                %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
                rtx = RocksDB.transaction(db)
                Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})

                tip_entry = DB.Chain.tip_entry()
                entry = chain_rewind_1(tip_entry, target_hash)

                RocksDB.put("temporal_tip", entry.hash, %{rtx: rtx, cf: cf.sysconf})
                RocksDB.put("temporal_height", entry.header_unpacked.height, %{rtx: rtx, cf: cf.sysconf, term: true})

                rooted_hash = RocksDB.get("rooted_tip", %{rtx: rtx, cf: cf.sysconf})
                rooted_entry = RocksDB.get(rooted_hash, %{rtx: rtx, cf: cf.entry})
                if !rooted_entry do
                    RocksDB.put("rooted_tip", entry.hash, %{rtx: rtx, cf: cf.sysconf})
                end

                :ok = RocksDB.transaction_commit(rtx)

                true
        end
    end
    defp chain_rewind_1(current_entry, target_hash) do
        m_rev = Consensus.chain_muts_rev(current_entry.hash)
        ConsensusKV.revert(m_rev)

        %{rtx: rtx, cf: cf} = Process.get({RocksDB, :ctx})
        RocksDB.delete(current_entry.hash, %{rtx: rtx, cf: cf.entry})
        RocksDB.delete(current_entry.hash, %{rtx: rtx, cf: cf.my_seen_time_for_entry})
        RocksDB.delete("#{current_entry.header_unpacked.height}:#{current_entry.hash}", %{rtx: rtx, cf: cf.entry_by_height})
        RocksDB.delete("#{current_entry.header_unpacked.slot}:#{current_entry.hash}", %{rtx: rtx, cf: cf.entry_by_slot})
        RocksDB.delete(current_entry.hash, %{rtx: rtx, cf: cf.consensus_by_entryhash})
        RocksDB.delete(current_entry.hash, %{rtx: rtx, cf: cf.my_attestation_for_entry})
        Enum.each(current_entry.txs, fn(tx_packed)->
            txu = TX.unpack(tx_packed)
            RocksDB.delete(txu.hash, %{rtx: rtx, cf: cf.tx})
            nonce_padded = String.pad_leading("#{txu.tx.nonce}", 20, "0")
            RocksDB.delete("#{txu.tx.signer}:#{nonce_padded}", %{rtx: rtx, cf: cf.tx_account_nonce})
            TX.known_receivers(txu)
            |> Enum.each(fn(receiver)->
                RocksDB.delete("#{receiver}:#{nonce_padded}", %{rtx: rtx, cf: cf.tx_receiver_nonce})
            end)
        end)

        if current_entry.hash == target_hash do
            prev_entry = Fabric.entry_by_hash_w_mutsrev(current_entry.header_unpacked.prev_hash)
            if !prev_entry do
                IO.puts "rewind catastrophically failed"
                :erlang.halt()
            else
                prev_entry
            end
        else
            case Fabric.entry_by_hash_w_mutsrev(current_entry.header_unpacked.prev_hash) do
                nil ->
                    IO.puts "rewind catastrophically failed"
                    :erlang.halt()
                #prev_entry = %{hash: ^target_hash} -> prev_entry
                prev_entry -> chain_rewind_1(prev_entry, target_hash)
            end
        end
    end

    def is_in_chain(target_hash) do
        case Fabric.entry_by_hash_w_mutsrev(target_hash) do
            nil -> false
            %{header_unpacked: %{height: target_height}} ->
                tip_entry = DB.Chain.tip_entry()
                tip_hash  = tip_entry.hash
                tip_height = tip_entry.header_unpacked.height

                if tip_height < target_height do
                  false
                else
                  is_in_chain_1(tip_hash, target_hash, target_height)
                end
        end
    end
    defp is_in_chain_1(current_hash, target_hash, target_height) do
        case Fabric.entry_by_hash_w_mutsrev(current_hash) do
            nil -> false
            %{hash: ^target_hash} -> true
            %{header_unpacked: %{prev_hash: prev_hash, height: height}} ->
                cond do
                  height <= target_height -> false
                  true -> is_in_chain_1(prev_hash, target_hash, target_height)
                end
        end
    end

    def best_by_weight(trainers, consensuses) do
        maxScore = length(trainers)
        Enum.reduce(consensuses, {nil,nil,nil}, fn({k,v}, {best,bestscore,bestval})->
            trainers_signed = BLS12AggSig.unmask_trainers(trainers, v.mask)
            score = Enum.reduce(trainers_signed, 0, fn(pk, acc)->
                acc + ConsensusWeight.count(pk)
            end)
            score = score/maxScore
            cond do
                !best -> {k, score, v}
                score > bestscore -> {k, score, v}
                true -> {best,bestscore,bestval}
            end
        end)
    end

    def make_mapenv(next_entry) do
        %{
            :readonly => false,
            :seed => nil,
            :seedf64 => 1.0,
            :entry_signer => next_entry.header_unpacked.signer,
            :entry_prev_hash => next_entry.header_unpacked.prev_hash,
            :entry_slot => next_entry.header_unpacked.slot,
            :entry_prev_slot => next_entry.header_unpacked.prev_slot,
            :entry_height => next_entry.header_unpacked.height,
            :entry_epoch => div(next_entry.header_unpacked.height, 100_000),
            :entry_vr => next_entry.header_unpacked.vr,
            :entry_vr_b3 => Blake3.hash(next_entry.header_unpacked.vr),
            :entry_dr => next_entry.header_unpacked.dr,
            :tx_index => 0,
            :tx_signer => nil, #env.txu.tx.signer,
            :tx_nonce => nil, #env.txu.tx.nonce,
            :tx_hash => nil, #env.txu.hash,
            :account_origin => nil, #env.txu.tx.signer,
            :account_caller => nil, #env.txu.tx.signer,
            :account_current => nil, #action.contract,
            :attached_symbol => "",
            :attached_amount => "",
            :call_counter => 0,
            :call_exec_points => 10_000_000,
            :call_exec_points_remaining => 10_000_000,
        }
    end

    def apply_entry(next_entry) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        height = RocksDB.get("temporal_height", %{db: db, cf: cf.sysconf, term: true})
        if !height or (height + 1) == Entry.height(next_entry) do
            apply_entry_1(next_entry)
        else
            %{error: :invalid_height}
        end
    end
    def apply_entry_1(next_entry) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})

        entry = next_entry
        next_entry_trimmed_map = %{
            entry_signer: entry.header_unpacked.signer,
            entry_prev_hash: entry.header_unpacked.prev_hash,
            entry_vr: entry.header_unpacked.vr,
            entry_vr_b3: Blake3.hash(entry.header_unpacked.vr),
            entry_dr: entry.header_unpacked.dr,
            entry_slot: entry.header_unpacked.slot,
            entry_prev_slot: entry.header_unpacked.prev_slot,
            entry_height: entry.header_unpacked.height,
            entry_epoch: div(entry.header_unpacked.height,100_000),
        }
        txus = Enum.map(entry.txs, & TX.unpack(&1))

        {rtx, m, m_rev, l} = RDB.apply_entry(db, next_entry_trimmed_map, Application.fetch_env!(:ama, :trainer_pk), Application.fetch_env!(:ama, :trainer_sk), entry.txs, txus)
        rebuild_m_fn = fn(m)->
          Enum.map(m, fn(inner)->
            op = :'#{IO.iodata_to_binary(inner[~c"op"])}'
            case op do
              :set_bit -> %{op: op, key: IO.iodata_to_binary(inner[~c"key"]), value: :erlang.binary_to_integer("#{inner[~c"value"]}"), bloomsize: :erlang.binary_to_integer("#{inner[~c"bloomsize"]}")}
              :clear_bit -> %{op: op, key: IO.iodata_to_binary(inner[~c"key"]), value: :erlang.binary_to_integer("#{inner[~c"value"]}")}
              :delete -> %{op: op, key: IO.iodata_to_binary(inner[~c"key"])}
              :put -> %{op: op, key: IO.iodata_to_binary(inner[~c"key"]), value: IO.iodata_to_binary(inner[~c"value"])}
            end
          end)
        end
        rebuild_l_fn = fn(m)->
          Enum.map(m, fn(inner)->
            %{error: :"#{IO.iodata_to_binary(inner["error"])}"}
          end)
        end
        m = rebuild_m_fn.(m)
        m_rev = rebuild_m_fn.(m_rev)
        l = rebuild_l_fn.(l)

        #call the exit
        Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})
        mapenv = make_mapenv(next_entry)
        {m_exit, m_exit_rev} = BIC.Base.call_exit(mapenv)
        m = m ++ m_exit
        m_rev = m_rev ++ m_exit_rev

        #{m, m_rev, l, ConsensusKV.hash_mutations(l ++ m ++ m_rev)}
        mutations_hash = ConsensusKV.hash_mutations(l ++ m)

        sk = Application.fetch_env!(:ama, :trainer_sk)
        attestation = Attestation.sign(sk, next_entry.hash, mutations_hash)
        attestation_packed = Attestation.pack(attestation)
        RocksDB.put(next_entry.hash, attestation_packed, %{rtx: rtx, cf: cf.my_attestation_for_entry})

        trainers = DB.Chain.validators_for_height(Entry.height(next_entry), %{rtx: rtx, cf: cf.contractstate})
        validator_seeds = Application.fetch_env!(:ama, :keys) |> Enum.filter(& &1.pk in trainers)

        seen_time = :os.system_time(1000)
        RocksDB.put(next_entry.hash, seen_time, %{rtx: rtx, cf: cf.my_seen_time_for_entry, term: true})

        RocksDB.put("temporal_tip", next_entry.hash, %{rtx: rtx, cf: cf.sysconf})
        RocksDB.put("temporal_height", next_entry.header_unpacked.height, %{rtx: rtx, cf: cf.sysconf, term: true})
        #:ok = :rocksdb.transaction_put(rtx, cf.my_mutations_hash_for_entry, next_entry.hash, mutations_hash)
        RocksDB.put(next_entry.hash, m_rev, %{rtx: rtx, cf: cf.muts_rev, term: true})

       # RocksDB.put(next_entry.header_unpacked.prev_hash, %{prev: prev, next: next_entry.hash}, %{rtx: rtx, cf: cf.entry_link})
       # RocksDB.put("000000000023", next_entry.hash, %{rtx: rtx, cf: cf.entry_link})


        entry_packed = RocksDB.get(next_entry.hash, %{rtx: rtx, cf: cf.entry})
        Enum.each(Enum.zip(next_entry.txs, l), fn({tx_packed, result})->
            txu = TX.unpack(tx_packed)
            case :binary.match(entry_packed, tx_packed) do
              {index_start, index_size} ->
                value = %{entry_hash: next_entry.hash, result: result, index_start: index_start, index_size: index_size}
                value = :erlang.term_to_binary(value, [:deterministic])
                RocksDB.put(txu.hash, value, %{rtx: rtx, cf: cf.tx})

                nonce_padded = String.pad_leading("#{txu.tx.nonce}", 20, "0")
                RocksDB.put("#{txu.tx.signer}:#{nonce_padded}", txu.hash, %{rtx: rtx, cf: cf.tx_account_nonce})
                TX.known_receivers(txu)
                |> Enum.each(fn(receiver)->
                    RocksDB.put("#{receiver}:#{nonce_padded}", txu.hash, %{rtx: rtx, cf: cf.tx_receiver_nonce})
                end)
            end
        end)

        if Application.fetch_env!(:ama, :archival_node) do
            RocksDB.put(next_entry.hash, m, %{rtx: rtx, cf: cf.muts, term: true})
        end

        :ok = RocksDB.transaction_commit(rtx)

        %{error: :ok, hash: next_entry.hash, validator_seeds: validator_seeds, mutations_hash: mutations_hash, logs: l, muts: m}
    end

    def produce_entry(sk, slot) do
        cur_entry = DB.Chain.tip_entry()
        next_entry = Entry.build_next(sk, cur_entry, slot)

        #TODO: embed aggsig of previous vote
        txs = TXPool.grab_next_valid(100)
        next_entry = Map.put(next_entry, :txs, txs)
        next_entry = Entry.sign(sk, next_entry)

        next_entry
    end
end

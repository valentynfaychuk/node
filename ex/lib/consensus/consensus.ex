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

        entry = Fabric.entry_by_hash(c.entry_hash)
        if !entry, do: throw(%{error: :invalid_entry})
        if entry.header_unpacked.height > Consensus.chain_height(), do: throw(%{error: :too_far_in_future})

        #TODO: race here if entry is not proced
        trainers = trainers_for_height(Entry.height(entry))
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

    def is_trainer() do
        Application.fetch_env!(:ama, :trainer_pk) in trainers_for_height(chain_height()+1)
    end

    def trainers_for_height(height, opts \\ %{}) do
        options = if opts[:rtx] do
            %{rtx: opts.rtx, cf: opts.cf.contractstate, term: true}
        else
            %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
            %{db: db, cf: cf.contractstate, term: true}
        end

        cond do
            height in 3195570..3195575 ->
                RocksDB.get("bic:epoch:trainers:height:000000319557", options)
            true ->
                {_, value} = RocksDB.get_prev_or_first("bic:epoch:trainers:height:", String.pad_leading("#{height}", 12, "0"), options)
                value
        end
    end

    def trainer_for_slot(height, slot) do
        trainers = trainers_for_height(height)
        index = rem(slot, length(trainers))
        Enum.at(trainers, index)
    end

    def trainer_for_slot_current() do
        trainer_for_slot(chain_height(), chain_height())
    end

    def trainer_for_slot_next() do
        trainer_for_slot(chain_height()+1, chain_height()+1)
    end

    def trainer_for_slot_next_me?() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        pk == trainer_for_slot_next()
    end

    def did_trainer_sign_consensus(trainer, entry_hash) do
        c = Fabric.consensuses_by_entryhash(entry_hash)
        if c do
            entry = Fabric.entry_by_hash(entry_hash)
            trainers = trainers_for_height(entry.header_unpacked.height)
            res = Enum.reject(c, fn {_mut_hash, %{mask: mask}}->
                signed = BLS12AggSig.unmask_trainers(trainers, mask)
                trainer in signed
            end)
            res == []
        end
    end

    def missing_signatures_for_consensus() do
      %{hash: hash, header_unpacked: %{height: height}} = Consensus.chain_tip_entry()
      trainers = Consensus.trainers_for_height(height)
      consensuses = Fabric.consensuses_by_entryhash(hash)
      {_, _score, c} = Consensus.best_by_weight(trainers, consensuses)
      trainers_signed = BLS12AggSig.unmask_trainers(trainers, c.mask)
      trainers -- trainers_signed
    end

    #def next_trainer_slot_in_x_slots(pk, epoch, slot, acc \\ 0) do
    #    trainer = Consensus.trainer_for_slot(epoch, slot + acc)
    #    cond do
    #        acc >= 128 -> nil
    #        pk == trainer -> acc
    #        true -> next_trainer_slot_in_x_slots(pk, epoch, slot, acc + 1)
    #    end
    #end

    def chain_height() do
        entry = chain_tip_entry()
        entry.header_unpacked.height
    end

    def chain_epoch() do
        div(chain_height(), 100_000)
    end

    def chain_segment_vr_hash() do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get("bic:epoch:segment_vr_hash", %{db: db, cf: cf.contractstate})
    end

    def chain_diff_bits() do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get("bic:epoch:diff_bits", %{db: db, cf: cf.contractstate, to_integer: true}) || 24
    end

    def chain_total_sols() do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get("bic:epoch:total_sols", %{db: db, cf: cf.contractstate, to_integer: true}) || 0
    end

    def chain_pop(pk) do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get("bic:epoch:pop:#{pk}", %{db: db, cf: cf.contractstate})
    end

    def chain_nonce(pk) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("bic:base:nonce:#{pk}", %{db: db, cf: cf.contractstate, to_integer: true})
    end

    def chain_balance(pk, symbol \\ "AMA") do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("bic:coin:balance:#{pk}:#{symbol}", %{db: db, cf: cf.contractstate, to_integer: true}) || 0
    end

    def chain_tip() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("temporal_tip", %{db: db, cf: cf.sysconf})
    end

    def chain_tip_entry() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(chain_tip(), %{db: db, cf: cf.entry, term: true})
        |> Entry.unpack()
    end

    def chain_muts_rev(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.muts_rev ,term: true})
    end

    def chain_muts(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.muts ,term: true})
    end

    def chain_rewind(target_hash) do
        in_chain = Consensus.is_in_chain(target_hash)
        cond do
            !in_chain -> false
            true ->
                %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
                rtx = RocksDB.transaction(db)
                Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})

                tip_entry = Consensus.chain_tip_entry()
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

    def chain_tx(tx_hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        map = RocksDB.get(tx_hash, %{db: db, cf: cf.tx ,term: true})
        if map do
            entry_bytes = RocksDB.get(map.entry_hash, %{db: db, cf: cf.entry})
            entry = Fabric.entry_by_hash(map.entry_hash)
            tx_bytes = binary_part(entry_bytes, map.index_start, map.index_size)
            TX.unpack(tx_bytes)
            |> Map.put(:result, map[:result])
            |> Map.put(:metadata, %{entry_hash: map.entry_hash, entry_slot: entry.header_unpacked.slot})
        end
    end

    def is_in_chain(target_hash) do
        case Fabric.entry_by_hash_w_mutsrev(target_hash) do
            nil -> false
            %{header_unpacked: %{height: target_height}} ->
                tip_entry = Consensus.chain_tip_entry()
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

    def apply_entry_old(next_entry) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})

        {m, m_rev, l, mhash} = try do apply_entry(next_entry) catch _,_ -> {nil,nil,nil,nil} end

        rtx = RocksDB.transaction(db)
        height = RocksDB.get("temporal_height", %{rtx: rtx, cf: cf.sysconf, term: true})
        if !height or (height + 1) == Entry.height(next_entry) do
            apply_entry_old_1(next_entry, cf, rtx, {m, m_rev, l, mhash})
        else
            %{error: :invalid_height}
        end
    end
    def apply_entry_old_1(next_entry, cf, rtx, lol) do
        # HALT before applying entry 34099999 for inspection
        #if next_entry.header_unpacked.height == 34099999 do
        #    IO.puts "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        #    IO.puts "HALTING BEFORE APPLYING HEIGHT 34099999"
        #    IO.puts "Entry hash: #{Base.encode16(next_entry.hash)}"
        #    IO.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
        #    :erlang.halt(0)
        #end

        Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})

        mapenv = make_mapenv(next_entry)

        txus = Enum.map(next_entry.txs, & TX.unpack(&1))
        {m_pre, m_rev_pre} = BIC.Base.call_txs_pre_parallel(mapenv, txus)

        {m, m_rev, l} = Enum.reduce(Enum.with_index(txus), {m_pre, m_rev_pre, []}, fn({txu, tx_idx}, {m, m_rev, l})->
            #ts_m = :os.system_time(1000)
            mapenv = Map.merge(mapenv, %{tx_index: tx_idx, tx_signer: txu.tx.signer, tx_nonce: txu.tx.nonce, tx_hash: txu.hash,
                account_origin: txu.tx.signer, account_caller: txu.tx.signer})
            {m3, m_rev3, m3_gas, m3_gas_rev, result} = BIC.Base.call_tx_actions(mapenv, txu)
            #IO.inspect {:call_tx, :os.system_time(1000) - ts_m}
            if result[:error] == :ok do
                m = m ++ m3 ++ m3_gas
                m_rev = m_rev ++ m_rev3 ++ m3_gas_rev
                {m, m_rev, l ++ [result]}
            else
                ConsensusKV.revert(m_rev3)
                {m ++ m3_gas, m_rev ++ m3_gas_rev, l ++ [result]}
            end
        end)
        {m_exit, m_exit_rev} = BIC.Base.call_exit(mapenv)

        Process.delete(SolVerifiedCache)

        m = m ++ m_exit
        m_rev = m_rev ++ m_exit_rev

        #TODO: store logs
        #IO.inspect {l ++ m, ConsensusKV.hash_mutations(l ++ m)}, limit: 11111111
        #IO.inspect {:real, next_entry.header_unpacked.height, m_rev, l, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}
        #File.write! "/tmp/real", inspect({:real, next_entry.header_unpacked.height, m, m_rev, l, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}, pretty: true, limit: 11111111, printable_limit: 111111111) <> "\n", [:append]
        #IO.inspect {:real, next_entry.header_unpacked.height, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}

        {m2, m_rev2, l2, mhash2} = lol
        doit = ConsensusKV.hash_mutations(l ++ m ++ m_rev)
        if doit != mhash2 do
          File.write! "/tmp/real", inspect({:real, next_entry.header_unpacked.height, m, m_rev, l, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}, pretty: true, limit: 11111111, printable_limit: 111111111) <> "\n", [:append]
          if mhash2 != nil do
            File.write! "/tmp/fake", inspect({:fake, next_entry.header_unpacked.height, m2, m_rev2, l2, Base58.encode(ConsensusKV.hash_mutations(l2 ++ m2))}, pretty: true, limit: 11111111, printable_limit: 111111111) <> "\n", [:append]
          end
        end

        mutations_hash = ConsensusKV.hash_mutations(l ++ m)

        attestation = Attestation.sign(next_entry.hash, mutations_hash)
        attestation_packed = Attestation.pack(attestation)
        RocksDB.put(next_entry.hash, attestation_packed, %{rtx: rtx, cf: cf.my_attestation_for_entry})

        pk = Application.fetch_env!(:ama, :trainer_pk)
        trainers = trainers_for_height(Entry.height(next_entry), %{rtx: rtx, cf: cf})
        is_trainer = pk in trainers

        seen_time = :os.system_time(1000)
        RocksDB.put(next_entry.hash, seen_time, %{rtx: rtx, cf: cf.my_seen_time_for_entry, term: true})

        RocksDB.put("temporal_tip", next_entry.hash, %{rtx: rtx, cf: cf.sysconf})
        RocksDB.put("temporal_height", next_entry.header_unpacked.height, %{rtx: rtx, cf: cf.sysconf, term: true})
        #:ok = :rocksdb.transaction_put(rtx, cf.my_mutations_hash_for_entry, next_entry.hash, mutations_hash)
        RocksDB.put(next_entry.hash, m_rev, %{rtx: rtx, cf: cf.muts_rev, term: true})

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

        ap = if is_trainer do
            #TODO: not ideal in super tight latency constrains but its 1 line and it works
            send(FabricCoordinatorGen, {:add_attestation, attestation})
            attestation_packed
        end

        %{error: :ok, attestation_packed: ap, mutations_hash: mutations_hash, logs: l, muts: m}
    end

    def apply_entry2(next_entry) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        height = RocksDB.get("temporal_height", %{db: db, cf: cf.sysconf, term: true})
        if !height or (height + 1) == Entry.height(next_entry) do
            apply_entry_2_1(next_entry)
        else
            %{error: :invalid_height}
        end
    end
    def apply_entry_2_1(next_entry) do
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
            %{error: :"#{inner["error"]}"}
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

        RDB.transaction_rollback(rtx)
        #IO.inspect {:fake, next_entry.header_unpacked.height, m, m_rev, l, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}
        File.write! "/tmp/fake", inspect({:fake, next_entry.header_unpacked.height, m, m_rev, l, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}, pretty: true, limit: 11111111, printable_limit: 111111111) <> "\n", [:append]
        IO.inspect {:fake, next_entry.header_unpacked.height, Base58.encode(ConsensusKV.hash_mutations(l ++ m))}
        1/0

        #TODO: store logs
        #IO.inspect {l ++ m, ConsensusKV.hash_mutations(l ++ m)}, limit: 11111111
        mutations_hash = ConsensusKV.hash_mutations(l ++ m)

        # DEBUG: Dump mutations for height 34099999
        if next_entry.header_unpacked.height == 34099999 do
            IO.puts "HEIGHT: #{next_entry.header_unpacked.height} | MUTATIONS_HASH: #{Base58.encode(mutations_hash)}"

            # Save to files
            File.write!("next_muts", :erlang.term_to_binary(m))
            File.write!("next_logs", :erlang.term_to_binary(l))
            File.write!("next_muts_rev", :erlang.term_to_binary(m_rev))
        end

        attestation = Attestation.sign(next_entry.hash, mutations_hash)
        attestation_packed = Attestation.pack(attestation)
        RocksDB.put(next_entry.hash, attestation_packed, %{rtx: rtx, cf: cf.my_attestation_for_entry})

        pk = Application.fetch_env!(:ama, :trainer_pk)
        trainers = trainers_for_height(Entry.height(next_entry), %{rtx: rtx, cf: cf})
        is_trainer = pk in trainers

        seen_time = :os.system_time(1000)
        RocksDB.put(next_entry.hash, seen_time, %{rtx: rtx, cf: cf.my_seen_time_for_entry, term: true})

        RocksDB.put("temporal_tip", next_entry.hash, %{rtx: rtx, cf: cf.sysconf})
        RocksDB.put("temporal_height", next_entry.header_unpacked.height, %{rtx: rtx, cf: cf.sysconf, term: true})
        #:ok = :rocksdb.transaction_put(rtx, cf.my_mutations_hash_for_entry, next_entry.hash, mutations_hash)
        RocksDB.put(next_entry.hash, m_rev, %{rtx: rtx, cf: cf.muts_rev, term: true})

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

        ap = if is_trainer do
            #TODO: not ideal in super tight latency constrains but its 1 line and it works
            send(FabricCoordinatorGen, {:add_attestation, attestation})
            attestation_packed
        end

        %{error: :ok, attestation_packed: ap, mutations_hash: mutations_hash, logs: l, muts: m}
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
        # HALT before applying entry 34099999 for inspection
        #if next_entry.header_unpacked.height == 34099999 do
        #    IO.puts "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        #    IO.puts "HALTING BEFORE APPLYING HEIGHT 34099999"
        #    IO.puts "Entry hash: #{Base.encode16(next_entry.hash)}"
        #    IO.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
        #    :erlang.halt(0)
        #end

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

        # DEBUG: Dump mutations for height 34099999
        if next_entry.header_unpacked.height == 34099999 do
            IO.puts "HEIGHT: #{next_entry.header_unpacked.height} | MUTATIONS_HASH: #{Base58.encode(mutations_hash)}"

            # Save to files
            File.write!("next_muts", :erlang.term_to_binary(m))
            File.write!("next_logs", :erlang.term_to_binary(l))
            File.write!("next_muts_rev", :erlang.term_to_binary(m_rev))
        end

        sk = Application.fetch_env!(:ama, :trainer_sk)
        attestation = Attestation.sign(sk, next_entry.hash, mutations_hash)
        attestation_packed = Attestation.pack(attestation)
        RocksDB.put(next_entry.hash, attestation_packed, %{rtx: rtx, cf: cf.my_attestation_for_entry})

        trainers = trainers_for_height(Entry.height(next_entry), %{rtx: rtx, cf: cf})
        validator_seeds = Application.fetch_env!(:ama, :keys) |> Enum.filter(& &1.pk in trainers)

        seen_time = :os.system_time(1000)
        RocksDB.put(next_entry.hash, seen_time, %{rtx: rtx, cf: cf.my_seen_time_for_entry, term: true})

        RocksDB.put("temporal_tip", next_entry.hash, %{rtx: rtx, cf: cf.sysconf})
        RocksDB.put("temporal_height", next_entry.header_unpacked.height, %{rtx: rtx, cf: cf.sysconf, term: true})
        #:ok = :rocksdb.transaction_put(rtx, cf.my_mutations_hash_for_entry, next_entry.hash, mutations_hash)
        RocksDB.put(next_entry.hash, m_rev, %{rtx: rtx, cf: cf.muts_rev, term: true})

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
        cur_entry = chain_tip_entry()
        next_entry = Entry.build_next(sk, cur_entry, slot)

        #TODO: embed aggsig of previous vote
        txs = TXPool.grab_next_valid(100)
        next_entry = Map.put(next_entry, :txs, txs)
        next_entry = Entry.sign(sk, next_entry)

        next_entry
    end
end

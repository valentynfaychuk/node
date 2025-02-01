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
        trainers = Consensus.trainers_for_epoch(Entry.epoch(entry))
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

    def is_trainer_for_epoch(trainer, epoch, opts \\ %{}) do
        trainers = trainers_for_epoch(epoch, opts) || []
        trainer in trainers
    end

    def trainers_for_epoch(epoch, opts \\ %{}) do
        if opts[:rtx] do
            RocksDB.get("bic:epoch:trainers:#{epoch}", %{rtx: opts.rtx, cf: opts.cf.contractstate, term: true})
        else
            %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
            RocksDB.get("bic:epoch:trainers:#{epoch}", %{db: db, cf: cf.contractstate, term: true})
        end
    end

    def trainer_for_slot(epoch, slot) do
        trainers = trainers_for_epoch(epoch)
        index = rem(slot, length(trainers))
        Enum.at(trainers, index)
    end

    def next_trainer_slot_in_x_slots(pk, epoch, slot, acc \\ 0) do
        trainer = Consensus.trainer_for_slot(epoch, slot + acc)
        cond do
            acc >= 128 -> nil
            pk == trainer -> acc
            true -> next_trainer_slot_in_x_slots(pk, epoch, slot, acc + 1)
        end
    end

    def chain_height() do
        entry = chain_tip_entry()
        entry.header_unpacked.height
    end

    def chain_epoch() do
        div(chain_height(), 100_000)
    end

    def chain_nonce(pk) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("bic:base:nonce:#{pk}", %{db: db, cf: cf.contractstate, term: true})
    end

    def chain_balance(pk) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("bic:coin:balance:#{pk}", %{db: db, cf: cf.contractstate, term: true}) || 0
    end

    def chain_tip() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("temporal_tip", %{db: db, cf: cf.sysconf})
    end

    def chain_tip_entry() do
        %{db: db} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(chain_tip(), %{db: db, term: true})
        |> Entry.unpack()
    end

    def chain_muts_rev(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.muts_rev ,term: true})
    end

    def chain_rewind(target_hash) do
        in_chain = Consensus.is_in_chain(target_hash)
        cond do
            !in_chain -> false
            true ->
                %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
                {:ok, rtx} = :rocksdb.transaction(db, [])
                Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})

                tip_entry = Consensus.chain_tip_entry()
                entry = chain_rewind_1(tip_entry, target_hash)

                :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_tip", entry.hash)
                :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_height", :erlang.term_to_binary(entry.header_unpacked.height, [:deterministic]))
                :ok = :rocksdb.transaction_commit(rtx)

                true
        end
    end
    defp chain_rewind_1(current_entry, target_hash) do
        m_rev = Consensus.chain_muts_rev(current_entry.hash)
        ConsensusKV.revert(m_rev)

        case Fabric.entry_by_hash_w_mutsrev(current_entry.header_unpacked.prev_hash) do
            nil ->
                IO.puts "rewind catastrophically failed"
                :erlang.halt()
            entry = %{hash: ^target_hash} -> entry
            current_entry -> chain_rewind_1(current_entry, target_hash)
        end
    end

    def am_i_in_slot() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        entry = Consensus.chain_tip_entry()
        next_epoch = div(entry.header_unpacked.height+1, 100_000)
        pk == trainer_for_slot(next_epoch, entry.header_unpacked.slot + 1)
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
                  height < target_height -> false
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

    def apply_entry(next_entry) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        {:ok, rtx} = :rocksdb.transaction(db, [])
        height = RocksDB.get("temporal_height", %{rtx: rtx, cf: cf.sysconf, term: true})
        if !height or height + 1 == Entry.height(next_entry) do
            apply_entry_1(next_entry, cf, rtx)
        else
            %{error: :invalid_height}
        end
    end
    def apply_entry_1(next_entry, cf, rtx) do
        Process.put({RocksDB, :ctx}, %{rtx: rtx, cf: cf})

        {m, m_rev, l} = Enum.reduce(next_entry.txs, {[], [], []}, fn(tx_packed, {m, m_rev, l})->
            txu = TX.unpack(tx_packed)
            
            {m2, m_rev2} = BIC.Base.call_tx_pre(%{entry: next_entry, txu: txu})
            m = m ++ m2
            m_rev = m_rev ++ m_rev2

            #ts_m = :os.system_time(1000)
            {m3, m_rev3, result} = BIC.Base.call_tx_actions(%{entry: next_entry, txu: txu})
            #IO.inspect {:call_tx, :os.system_time(1000) - ts_m}
            if result == %{error: :ok} do
                m = m ++ m3
                m_rev = m_rev ++ m_rev3
                {m, m_rev, l ++ [%{error: :ok}]}
            else
                ConsensusKV.revert(m_rev3)
                {m, m_rev, l ++ [result]}
            end
        end)
        {m_exit, m_exit_rev} = BIC.Base.call_exit(%{entry: next_entry})

        m = m ++ m_exit
        m_rev = m_rev ++ m_exit_rev

        #TODO: store logs
        #IO.inspect {l ++ m, ConsensusKV.hash_mutations(l ++ m)}, limit: 11111111
        mutations_hash = ConsensusKV.hash_mutations(l ++ m)

        #TODO: also write attestaton
        #TODO: aggregate attestation
        attestation_packed = Attestation.pack(Attestation.sign(next_entry.hash, mutations_hash))
        :ok = :rocksdb.transaction_put(rtx, cf.my_attestation_for_entry, next_entry.hash, attestation_packed)
        
        pk = Application.fetch_env!(:ama, :trainer_pk)
        ap = if pk in trainers_for_epoch(Entry.epoch(next_entry), %{rtx: rtx, cf: cf}) do
            Fabric.aggregate_attestation(attestation_packed, %{rtx: rtx, cf: cf})
            attestation_packed
        end

        seen_time = :os.system_time(1000)
        :ok = :rocksdb.transaction_put(rtx, cf.my_seen_time_for_entry, next_entry.hash, :erlang.term_to_binary(seen_time, [:deterministic]))

        :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_tip", next_entry.hash)
        :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_height", :erlang.term_to_binary(next_entry.header_unpacked.height, [:deterministic]))
        #:ok = :rocksdb.transaction_put(rtx, cf.my_mutations_hash_for_entry, next_entry.hash, mutations_hash)
        :ok = :rocksdb.transaction_put(rtx, cf.muts_rev, next_entry.hash, :erlang.term_to_binary(m_rev, [:deterministic]))

        :ok = :rocksdb.transaction_commit(rtx)
        
        %{error: :ok, attestation_packed: ap, mutations_hash: mutations_hash}
    end

    def produce_entry(slot) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})

        cur_entry = chain_tip_entry()
        next_entry = Entry.build_next(cur_entry, slot)

        #TODO: todo add >1 tx
        #ts_m = :os.system_time(1000)
        #txs = TXPool.grab_next_valids(next_entry)
        txs = TXPool.grab_next_valid()
        #IO.inspect {:tx, :os.system_time(1000) - ts_m}

        next_entry = Map.put(next_entry, :txs, txs)
        next_entry = Entry.sign(next_entry)

        next_entry
    end
end
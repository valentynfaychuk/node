defmodule Consensus do

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
            txu = TX.unwrap(tx_packed)
            
            {m2, m_rev2} = BIC.Base.call_tx_pre(%{entry: next_entry, txu: txu})
            m = m ++ m2
            m_rev = m_rev ++ m_rev2

            {m3, m_rev3, result} = BIC.Base.call_tx_actions(%{entry: next_entry, txu: txu})
            if result == %{error: :ok} do
                m = m ++ m3
                m_rev = m_rev ++ m_rev3
                {m, m_rev, l ++ [%{error: :ok}]}
            else
                ConsensusKV.revert(m_rev3)
                {m, m_rev, l ++ [result]}
            end
        end)
        {m_base, m_base_rev} = BIC.Base.call_exit(%{entry: next_entry})

        m = m ++ m_base
        m_rev = m_rev ++ m_base_rev

        #TODO: store logs
        #IO.inspect {l ++ m, ConsensusKV.hash_mutations(l ++ m)}, limit: 11111111
        mutations_hash = ConsensusKV.hash_mutations(l ++ m)

        #TODO: also write attestaton
        #TODO: aggregate attestation
        attestation_packed = Attestation.pack(Attestation.sign(next_entry.hash, mutations_hash))
        :ok = :rocksdb.transaction_put(rtx, cf.my_attestation_for_entry, next_entry.hash, attestation_packed)
        
        pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
        ap = if pk_raw in trainers_for_epoch(Entry.epoch(next_entry), %{rtx: rtx, cf: cf}) do
            Fabric.aggregate_attestation(attestation_packed, %{rtx: rtx, cf: cf})
            attestation_packed
        end

        :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_tip", next_entry.hash)
        :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "temporal_height", :erlang.term_to_binary(next_entry.header_unpacked.height, [:deterministic]))
        :ok = :rocksdb.transaction_put(rtx, cf.muts_rev, next_entry.hash, :erlang.term_to_binary(m_rev, [:deterministic]))

        :ok = :rocksdb.transaction_commit(rtx)

        %{error: :ok, attestation_packed: ap, mutations_hash: mutations_hash}
    end

    def produce_entry(slot) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})

        cur_entry = chain_tip_entry()
        next_entry = Entry.build_next(cur_entry, slot)

        #TODO: todo add >1 tx
        txs = TXPool.grab_next_valids(next_entry)

        next_entry = Map.put(next_entry, :txs, txs)
        next_entry = Entry.sign(next_entry)

        Fabric.insert_entry(next_entry)
        next_entry
    end
end
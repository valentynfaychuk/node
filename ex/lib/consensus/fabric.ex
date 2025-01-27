defmodule Fabric do
    @args [
        {:target_file_size_base, 2 * 1024 * 1024 * 1024}, #2GB
        {:target_file_size_multiplier, 2}
    ]

    def init() do
        workdir = Application.fetch_env!(:ama, :work_folder)
        
        path = Path.join([workdir, "db/fabric/"])
        File.mkdir_p!(path)

        {:ok, db_ref, cf_ref_list} = :rocksdb.open_optimistic_transaction_db('#{path}',
          [
            {:create_if_missing, true}, {:create_missing_column_families, true},
            {:target_file_size_base, 2 * 1024 * 1024 * 1024}, #2GB
            {:target_file_size_multiplier, 2}
          ],
          [
            {'default', @args},
            {'entry_by_height|height:entryhash', @args},
            {'entry_by_slot|slot:entryhash', @args},
            {'tx|txhash:entryhash', @args},

            {'my_seen_time_entry|entryhash', @args},
            {'my_attestation_for_entry|entryhash', @args},
            #{'attestation|attestationhash', []},
            #{'attestation_for_entry|entryhash', []},
            #{'attestation_by_entry_signer|entryhash:signer:attestationhash', []},

            {'consensus', @args},
            {'consensus_by_entryhash|Map<mutationshash,consensus>', @args},

            {'contractstate', @args},
            {'muts_rev', @args},

            {'sysconf', @args},
          ]
        )
        [
            default_cf, entry_height_cf, entry_slot_cf, tx_cf,
            my_seen_time_for_entry_cf, my_attestation_for_entry_cf,
            consensus_cf, consensus_by_entryhash_cf,
            contractstate_cf, muts_rev_cf,
            sysconf_cf
        ] = cf_ref_list
        cf = %{
            default: default_cf, entry_by_height: entry_height_cf, entry_by_slot: entry_slot_cf, tx: tx_cf,
            my_seen_time_for_entry: my_seen_time_for_entry_cf, my_attestation_for_entry: my_attestation_for_entry_cf,
            consensus: consensus_cf, consensus_by_entryhash: consensus_by_entryhash_cf,
            contractstate: contractstate_cf, muts_rev: muts_rev_cf,
            sysconf: sysconf_cf
        }
        :persistent_term.put({:rocksdb, Fabric}, %{db: db_ref, cf_list: cf_ref_list, cf: cf, path: path})
    end

    def entry_by_hash(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, term: true})
        |> Entry.unpack()
    end

    def entry_by_hash_w_mutsrev(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        entry = RocksDB.get(hash, %{db: db, term: true})
        |> Entry.unpack()
        mutsrev = RocksDB.get(hash, %{db: db, cf: cf.muts_rev})
        if !!mutsrev and !!entry do
            entry
        end
    end

    def entry_seentime(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.my_seen_time_for_entry, term: true})
    end

    def entries_by_height(height) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get_prefix("#{height}:", %{db: db, cf: cf.entry_by_height})
        |> Enum.map(& Entry.unpack(entry_by_hash(elem(&1,0))))
    end

    def rooted_tip() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get("rooted_tip", %{db: db, cf: cf.sysconf})
    end

    def rooted_tip_entry() do
        entry_by_hash(rooted_tip())
    end

    def my_attestation_by_entryhash(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.my_attestation_for_entry, term: true})
    end

    def consensuses_by_entryhash(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.consensus_by_entryhash, term: true})
    end

    def best_consensus_by_entryhash(trainers, hash) do
        consensuses = consensuses_by_entryhash(hash)
        if !consensuses do {nil,nil} else
            {mut_hash, score, _consensus} = Consensus.best_by_weight(trainers, consensuses)
            {mut_hash, score}
        end
    end

    def set_rooted_tip(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        {:ok, rtx} = :rocksdb.transaction(db, [])
        :ok = :rocksdb.transaction_put(rtx, cf.sysconf, "rooted_tip", hash)
        :ok = :rocksdb.transaction_commit(rtx)
    end

    def insert_genesis() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        genesis = EntryGenesis.get()
        if !RocksDB.get(genesis.hash, %{db: db}) do
            IO.puts "🌌  Ahhh... Fresh Fabric. Marking genesis.."
            insert_entry(genesis)

            %{error: :ok, mutations_hash: mutations_hash} = Consensus.apply_entry(genesis)
            attestation = EntryGenesis.attestation()
            true = mutations_hash == attestation.mutations_hash

            aggregate_attestation(attestation)

            set_rooted_tip(genesis.hash)
            RocksDB.put("temporal_height", 0, %{db: db, cf: cf.sysconf, term: true})
        end
    end

    def insert_entry(e, seen_time \\ nil)
    def insert_entry(e, seen_time) when is_binary(e) do insert_entry(Entry.unpack(e), seen_time) end
    def insert_entry(e, seen_time) when is_map(e) do
        entry_packed = Entry.pack(e)

        seen_time = if seen_time do seen_time else :os.system_time(1000) end

        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        {:ok, rtx} = :rocksdb.transaction(db, [])
        has_entry = RocksDB.get(e.hash, %{rtx: rtx, cf: cf.default})
        if !has_entry do
            :ok = :rocksdb.transaction_put(rtx, cf.default, e.hash, entry_packed)
            :ok = :rocksdb.transaction_put(rtx, cf.my_seen_time_for_entry, e.hash, :erlang.term_to_binary(seen_time, [:deterministic]))
            :ok = :rocksdb.transaction_put(rtx, cf.entry_by_height, "#{e.header_unpacked.height}:#{e.hash}", e.hash)
            :ok = :rocksdb.transaction_put(rtx, cf.entry_by_slot, "#{e.header_unpacked.slot}:#{e.hash}", e.hash)
        end

        #TODO: key tx by <txhash>:<e.hash> value <index_start::32,index_end::32> inside the entry
        :ok = :rocksdb.transaction_commit(rtx)
    end

    def get_or_resign_my_attestation(entry_hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})

        attestation_packed = RocksDB.get(entry_hash, %{db: db, cf: cf.my_attestation_for_entry})
        if attestation_packed do
            a = Attestation.unpack(attestation_packed)

            if Application.fetch_env!(:ama, :trainer_pk) == a.signer do a else
                IO.puts "imported database, resigning attestation #{Base58.encode(entry_hash)}"
                a = Attestation.sign(entry_hash, a.mutations_hash)
                RocksDB.put(entry_hash, Attestation.pack(a), %{db: db, cf: cf.my_attestation_for_entry})
                a
            end
            |> Attestation.pack()
        end
    end

    def aggregate_attestation(a, opts \\ %{})
    def aggregate_attestation(a, opts) when is_binary(a) do aggregate_attestation(Attestation.unpack(a), opts) end
    def aggregate_attestation(a, opts) when is_map(a) do
        {cf, rtx} = if opts[:rtx] do
            {opts.cf, opts.rtx}
        else
            %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
            {:ok, rtx} = :rocksdb.transaction(db, [])
            {cf, rtx}
        end

        entry_hash = a.entry_hash
        mutations_hash = a.mutations_hash

        entry = entry_by_hash(entry_hash)
        trainers = if !entry do nil else Consensus.trainers_for_epoch(Entry.epoch(entry)) end
        if !!entry and !!trainers do
            true = a.signer in trainers

            consensuses = RocksDB.get(entry_hash, %{rtx: rtx, cf: cf.consensus_by_entryhash, term: true}) || %{}
            consensus = consensuses[mutations_hash]
            consensus = if consensus do
                BLS12AggSig.add(consensus, trainers, a.signer, a.signature)
            else
                BLS12AggSig.new(trainers, a.signer, a.signature)
            end
            consensuses = Map.put(consensuses, mutations_hash, consensus)
            :ok = :rocksdb.transaction_put(rtx, cf.consensus_by_entryhash, entry_hash, :erlang.term_to_binary(consensuses, [:deterministic]))

            if !opts[:rtx] do
                :ok = :rocksdb.transaction_commit(rtx)
            end
        end
    end
end
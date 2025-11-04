defmodule Fabric do
    @args [
        {:target_file_size_base, 2 * 1024 * 1024 * 1024}, #2GB
        {:target_file_size_multiplier, 2},
    ]

    def init() do
        workdir = Application.fetch_env!(:ama, :work_folder)

        path = Path.join([workdir, "db/fabric/"])
        File.mkdir_p!(path)

        cfs = [
          "default",
          "entry",
          "entry_by_height|height->entryhash",
          "entry_by_slot|slot->entryhash",

          #TODO: reversed columns by accident, fix it
          "my_seen_time_entry|entryhash->ts_sec",
          "my_attestation_for_entry|entryhash->attestation",

          "tx|txhash->entryhash",
          "tx_account_nonce|account:nonce->txhash",
          "tx_receiver_nonce|receiver:nonce->txhash",

          "consensus",
          "consensus_by_entryhash|Map<mutationshash,consensus>",

          "contractstate",
          "muts",
          "muts_rev",

          "sysconf",
          "attestations",
          "entry_meta",
          "entry_link",
        ]
        try do
          {:ok, db_ref, cf_ref_list} = RDB.open_transaction_db(path, cfs)
          [
              default_cf, entry_cf, entry_height_cf, entry_slot_cf,
              tx_cf, tx_account_nonce_cf, tx_receiver_nonce_cf,
              my_seen_time_for_entry_cf, my_attestation_for_entry_cf,
              consensus_cf, consensus_by_entryhash_cf,
              contractstate_cf, muts_cf, muts_rev_cf,
              sysconf_cf, attestations_cf, entry_meta_cf, entry_link_cf,
          ] = cf_ref_list
          cf = %{
              default: default_cf, entry: entry_cf, entry_by_height: entry_height_cf, entry_by_slot: entry_slot_cf,
              tx: tx_cf, tx_account_nonce: tx_account_nonce_cf, tx_receiver_nonce: tx_receiver_nonce_cf,
              my_seen_time_for_entry: my_seen_time_for_entry_cf, my_attestation_for_entry: my_attestation_for_entry_cf,
              #my_mutations_hash_for_entry: my_mutations_hash_for_entry_cf,
              consensus: consensus_cf, consensus_by_entryhash: consensus_by_entryhash_cf,
              contractstate: contractstate_cf, muts: muts_cf, muts_rev: muts_rev_cf,
              sysconf: sysconf_cf, attestations: attestations_cf, entry_meta: entry_meta_cf,
          }
          :persistent_term.put({:rocksdb, Fabric}, %{db: db_ref, cf_list: cf_ref_list, cf: cf, path: path})
        catch
          e,r ->
            IO.inspect {e, r}
            IO.inspect {:using_old_db, "node might stall during compression, either wait a long time to download from snapshot"}
            init_old()
        end
    end

    def init_old() do
        workdir = Application.fetch_env!(:ama, :work_folder)

        path = Path.join([workdir, "db/fabric/"])
        File.mkdir_p!(path)

        cfs = [
          "default",
          "entry_by_height|height:entryhash",
          "entry_by_slot|slot:entryhash",
          "my_seen_time_entry|entryhash",
          "my_attestation_for_entry|entryhash",

          "tx|txhash:entryhash",
          "tx_account_nonce|account:nonce->txhash",
          "tx_receiver_nonce|receiver:nonce->txhash",

          "consensus",
          "consensus_by_entryhash|Map<mutationshash,consensus>",

          "contractstate",
          "muts",
          "muts_rev",

          "sysconf",
        ]
        {:ok, db_ref, cf_ref_list} = RDB.open_transaction_db(path, cfs)
        [
            default_cf, entry_height_cf, entry_slot_cf,
            tx_cf, tx_account_nonce_cf, tx_receiver_nonce_cf,
            my_seen_time_for_entry_cf, my_attestation_for_entry_cf,
            consensus_cf, consensus_by_entryhash_cf,
            contractstate_cf, muts_cf, muts_rev_cf,
            sysconf_cf
        ] = cf_ref_list
        cf = %{
            default: default_cf, entry: default_cf, entry_by_height: entry_height_cf, entry_by_slot: entry_slot_cf,
            tx: tx_cf, tx_account_nonce: tx_account_nonce_cf, tx_receiver_nonce: tx_receiver_nonce_cf,
            my_seen_time_for_entry: my_seen_time_for_entry_cf, my_attestation_for_entry: my_attestation_for_entry_cf,
            #my_mutations_hash_for_entry: my_mutations_hash_for_entry_cf,
            consensus: consensus_cf, consensus_by_entryhash: consensus_by_entryhash_cf,
            contractstate: contractstate_cf, muts: muts_cf, muts_rev: muts_rev_cf,
            sysconf: sysconf_cf
        }
        :persistent_term.put({:rocksdb, Fabric}, %{db: db_ref, cf_list: cf_ref_list, cf: cf, path: path})
    end

    def close() do
        %{db: db} = :persistent_term.get({:rocksdb, Fabric})
        RDB.close_db(db)
    end

    def entry_by_hash_w_mutsrev(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        entry = RocksDB.get(hash, %{db: db, cf: cf.entry, term: true})
        |> Entry.unpack()
        mutsrev = RocksDB.get(hash, %{db: db, cf: cf.muts_rev})
        if !!mutsrev and !!entry do
            entry
        end
    end

    def entries_last_x(cnt) do
        entry = DB.Chain.tip_entry()
        entries_last_x_1(cnt - 1, entry.header_unpacked.prev_hash, [entry])
    end
    def entries_last_x_1(cnt, prev_hash, acc) when cnt <= 0, do: acc
    def entries_last_x_1(cnt, prev_hash, acc) do
        entry = DB.Chain.entry(prev_hash)
        entries_last_x_1(cnt - 1, entry.header_unpacked.prev_hash, [entry] ++ acc)
    end

    def my_attestation_by_height(height) do
        entries = DB.Chain.entries_by_height(height)
        Enum.find_value(entries, fn(entry)->
            my_attestation_by_entryhash(entry.hash)
        end)
    end

    def my_mutations_hash_for_entry(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get(hash, %{db: db, cf: cf.my_mutations_hash_for_entry})
    end

    def consensuses_by_height(height) do
        softfork_deny_hash = :persistent_term.get(SoftforkDenyHash, [])

        entries = DB.Chain.entries_by_height(height)
        |> Enum.reject(& &1.hash in softfork_deny_hash)
        Enum.map(entries, fn(entry)->
            map = consensuses_by_entryhash(entry.hash) || %{}
            Enum.map(map, fn {mutations_hash, %{mask: mask, aggsig: aggsig}} ->
                %{entry_hash: entry.hash, mutations_hash: mutations_hash, mask: mask, aggsig: aggsig}
            end)
        end)
        |> List.flatten()
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
        if !consensuses do {nil,nil,nil} else
            {mut_hash, score, consensus} = Consensus.best_by_weight(trainers, consensuses)
        end
    end

    def set_rooted_tip(hash) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        rtx = RocksDB.transaction(db)
        RocksDB.put("rooted_tip", hash, %{rtx: rtx, cf: cf.sysconf})
        :ok = RocksDB.transaction_commit(rtx)
    end

    def insert_genesis() do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        genesis = EntryGenesis.get()
        if !RocksDB.get(genesis.hash, %{db: db, cf: cf.entry}) do
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
        rtx = RocksDB.transaction(db)

        has_entry = RocksDB.get(e.hash, %{rtx: rtx, cf: cf.entry})
        if !has_entry do
            RocksDB.put(e.hash, entry_packed, %{rtx: rtx, cf: cf.entry})
            RocksDB.put(e.hash, seen_time, %{rtx: rtx, cf: cf.my_seen_time_for_entry, term: true})
            RocksDB.put("#{e.header_unpacked.height}:#{e.hash}", e.hash, %{rtx: rtx, cf: cf.entry_by_height})
            RocksDB.put("#{e.header_unpacked.slot}:#{e.hash}", e.hash, %{rtx: rtx, cf: cf.entry_by_slot})
        end

        RocksDB.transaction_commit(rtx)
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
            rtx = RocksDB.transaction(db)
            {cf, rtx}
        end

        entry_hash = a.entry_hash
        mutations_hash = a.mutations_hash

        entry = DB.Chain.entry(entry_hash)
        trainers = if !entry do nil else DB.Chain.validators_for_height(Entry.height(entry)) end
        if !!entry and !!trainers and a.signer in trainers do

            #FIX: make sure we dont race on the trainers_for_height
            if entry.header_unpacked.height <= DB.Chain.height() do
                consensuses = RocksDB.get(entry_hash, %{rtx: rtx, cf: cf.consensus_by_entryhash, term: true}) || %{}
                consensus = consensuses[mutations_hash]
                consensus = cond do
                    !consensus -> BLS12AggSig.new(trainers, a.signer, a.signature)
                    bit_size(consensus.mask) < length(trainers) -> BLS12AggSig.new(trainers, a.signer, a.signature)
                    true -> BLS12AggSig.add(consensus, trainers, a.signer, a.signature)
                end
                consensuses = Map.put(consensuses, mutations_hash, consensus)
                RocksDB.put(entry_hash, consensuses, %{rtx: rtx, cf: cf.consensus_by_entryhash, term: true})
            end

            if !opts[:rtx] do
                RocksDB.transaction_commit(rtx)
            end
        end
    end

    def insert_consensus(consensus) do
        entry_hash = consensus.entry_hash
        entry = DB.Chain.entry(entry_hash)
        {_, oldScore, _} = best_consensus_by_entryhash(DB.Chain.validators_for_height(Entry.height(entry)), entry_hash)
        if consensus.score >= 0.67 and consensus.score > (oldScore||0) do
            %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
            rtx = RocksDB.transaction(db)

            consensuses = RocksDB.get(entry_hash, %{rtx: rtx, cf: cf.consensus_by_entryhash, term: true}) || %{}
            consensuses = put_in(consensuses, [consensus.mutations_hash], %{mask: consensus.mask, aggsig: consensus.aggsig})
            RocksDB.put(entry_hash, consensuses, %{rtx: rtx, cf: cf.consensus_by_entryhash, term: true})
            RocksDB.transaction_commit(rtx)
        else
            #IO.inspect {:insert_consensus, :rejected_by_score, oldScore, consensus.score}
        end
    end
end

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
          "attestation",
        ]
        try do
          {:ok, db_ref, cf_ref_list} = RDB.open_transaction_db(path, cfs)
          [
              default_cf, entry_cf, entry_height_cf, entry_slot_cf,
              tx_cf, tx_account_nonce_cf, tx_receiver_nonce_cf,
              my_seen_time_for_entry_cf, my_attestation_for_entry_cf,
              consensus_cf, consensus_by_entryhash_cf,
              contractstate_cf, muts_cf, muts_rev_cf,
              sysconf_cf, attestations_cf, entry_meta_cf, entry_link_cf, attestation_cf,
          ] = cf_ref_list
          cf = %{
              default: default_cf, entry: entry_cf, entry_by_height: entry_height_cf, entry_by_slot: entry_slot_cf,
              tx: tx_cf, tx_account_nonce: tx_account_nonce_cf, tx_receiver_nonce: tx_receiver_nonce_cf,
              my_seen_time_for_entry: my_seen_time_for_entry_cf, my_attestation_for_entry: my_attestation_for_entry_cf,
              #my_mutations_hash_for_entry: my_mutations_hash_for_entry_cf,
              consensus: consensus_cf, consensus_by_entryhash: consensus_by_entryhash_cf,
              contractstate: contractstate_cf, muts: muts_cf, muts_rev: muts_rev_cf,
              sysconf: sysconf_cf, attestations: attestations_cf, entry_meta: entry_meta_cf, attestation: attestation_cf,
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
end

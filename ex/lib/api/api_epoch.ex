defmodule API.Epoch do
    def set_emission_address(pk) do
      pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
      sk = Application.fetch_env!(:ama, :trainer_sk)
      tx_packed = TX.build(sk, "Epoch", "set_emission_address", [pk])
      TXPool.insert_and_broadcast(tx_packed)
    end

    def get_emission_address() do
      pk = Application.fetch_env!(:ama, :trainer_pk)
      get_emission_address(pk)
    end

    def get_emission_address(pk) do
      pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
      API.Contract.get("bic:epoch:emission_address:#{pk}")
      |> case do
        nil -> nil
        addr -> Base58.encode(addr)
      end
    end

    def get_segment_vr_hash() do
      API.Contract.get("bic:epoch:segment_vr_hash")
      |> Base58.encode()
    end

    def get_diff_bits(epoch \\ nil) do
      epoch = if epoch do epoch else Consensus.chain_epoch() end
      API.Contract.get("bic:epoch:diff_bits:#{epoch}", :to_integer) || 24
    end

    def get_total_sols(epoch \\ nil) do
      epoch = if epoch do epoch else Consensus.chain_epoch() end
      API.Contract.get("bic:epoch:total_sols:#{epoch}", :to_integer) || 0
    end

    def get_pop(pk) do
      pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
      Consensus.chain_pop(pk)
      |> case do
        nil -> nil
        addr -> Base58.encode(addr)
      end
    end

    def score() do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get_prefix("bic:epoch:solutions_count:", %{db: db, cf: cf.contractstate, to_integer: true})
      |> Enum.map(fn {k, v} -> [Base58.encode(k), v] end)
      |> Enum.sort_by(& Enum.at(&1, 1), :desc)
    end

    def score_without_peddlebike() do
      pb67 = BIC.Epoch.peddlebike67()
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      RocksDB.get_prefix("bic:epoch:solutions_count:", %{db: db, cf: cf.contractstate, to_integer: true})
      |> Enum.reject(fn {k, v} -> k in pb67 end)
      |> Enum.map(fn {k, v} -> [Base58.encode(k), v] end)
      |> Enum.sort_by(& Enum.at(&1, 1), :desc)
    end

    def score(pk) do
      pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk

      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      score = RocksDB.get("bic:epoch:solutions_count:#{pk}", %{db: db, cf: cf.contractstate, to_integer: true}) || 0
      %{error: :ok, score: score}
    end
end

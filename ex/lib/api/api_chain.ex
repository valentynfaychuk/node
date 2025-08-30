defmodule API.Chain do
    def entry_tip() do
        entry = Consensus.chain_tip_entry()
        entry = format_entry_for_client(entry)
        %{error: :ok, entry: entry}
    end

    def entry(entry_hash) do
        entry_hash = if byte_size(entry_hash) != 32, do: Base58.decode(entry_hash), else: entry_hash
        entry = Fabric.entry_by_hash(entry_hash)
        if !entry do
            %{error: :not_found}
        else
            entry = format_entry_for_client(entry)
            %{error: :ok, entry: entry}
        end
    end

    def by_height(height) do
        entries = Fabric.entries_by_height(height)
        |> Enum.map(& format_entry_for_client(&1))
        %{error: :ok, entries: entries}
    end

    def by_height_with_txs(height) do
        entries = Fabric.entries_by_height(height)
        |> Enum.map(fn(entry)->
            txs = API.TX.get_by_entry(entry.hash)
            entry = format_entry_for_client(entry)
            Map.put(entry, :txs, txs)
        end)
        %{error: :ok, entries: entries}
    end

    def consensus_score_by_entryhash(hash, height) do
        consensuses = Fabric.consensuses_by_entryhash(hash)
        if !consensuses do
            {nil, nil}
        else
            trainers = Consensus.trainers_for_height(height)
            {mut_hash, score, consensus} = Consensus.best_by_weight(trainers, consensuses)
            {score, mut_hash}
        end
    end

    def consensuses_by_height(height) do
        Fabric.consensuses_by_height(height)
        |> Enum.map(fn(c)->
            c = put_in(c, [:mutations_hash], Base58.encode(c.mutations_hash))
            c = put_in(c, [:entry_hash], Base58.encode(c.entry_hash))
            c = put_in(c, [:aggsig], Base58.encode(c.aggsig))
            signers = BLS12AggSig.unmask_trainers(Consensus.trainers_for_height(height), c.mask)
            |> Enum.map(& Base58.encode(&1))
            c = put_in(c, [:signers], signers)
            c = put_in(c, [:score], length(c.signers) / bit_size(c.mask))
            Map.drop(c, [:mask])
        end)
    end

    def pflops() do
      #A*B=C M=16 K=50240 N=16 u8xi8=i32
      height_in_epoch = rem(Consensus.chain_height(), 100_000)
      total_score = API.Epoch.score() |> Enum.map(& Enum.at(&1,1))|> Enum.sum()
      diff_multiplier = 256*256*256
      total_calcs = total_score * diff_multiplier
      macs = 16*16*50240
      ops = macs*2

      seconds = height_in_epoch * 0.5 + 1
      ((total_calcs * ops) / seconds) / 1.0e15
    end

    def stats() do
      %{
        height: Consensus.chain_height(),
        tip_hash: Consensus.chain_tip() |> Base58.encode(),
        tip: format_entry_for_client(Consensus.chain_tip_entry()),
        tx_pool_size: NodePeers.size(),
        cur_validator: Consensus.trainer_for_slot_current() |> Base58.encode(),
        next_validator: Consensus.trainer_for_slot_next() |> Base58.encode(),
        emission_for_epoch: BIC.Coin.from_flat(BIC.Epoch.epoch_emission(Consensus.chain_epoch())),
        circulating: BIC.Coin.from_flat(BIC.Epoch.circulating_without_burn(Consensus.chain_epoch())),
        total_supply_y3: BIC.Coin.from_flat(BIC.Epoch.circulating_without_burn(500*3)),
        total_supply_y30: BIC.Coin.from_flat(BIC.Epoch.circulating_without_burn(500*30)),
        pflops: pflops(),
      }
    end

    def format_entry_for_client(entry) do
        hash = entry.hash
        entry = Map.put(entry, :tx_count, length(entry.txs))
        entry = Map.drop(entry, [:header, :signature, :txs])
        {_, entry} = pop_in(entry, [:header_unpacked, :txs_hash])
        entry = put_in(entry, [:hash], Base58.encode(entry.hash))
        entry = if !entry[:mask] do entry else
          rem     = rem(bit_size(entry.mask), 8)
          pad_bits = if rem == 0, do: 0, else: 8 - rem
          put_in(entry, [:mask], Base58.encode(<<entry.mask::bitstring, 0::size(pad_bits)>>))
        end
        entry = put_in(entry, [:header_unpacked, :dr], Base58.encode(entry.header_unpacked.dr))
        entry = put_in(entry, [:header_unpacked, :vr], Base58.encode(entry.header_unpacked.vr))
        entry = put_in(entry, [:header_unpacked, :prev_hash], Base58.encode(entry.header_unpacked.prev_hash))
        entry = put_in(entry, [:header_unpacked, :signer], Base58.encode(entry.header_unpacked.signer))
        {score, mut_hash} = consensus_score_by_entryhash(hash, entry.header_unpacked.height)
        if !score do entry else
            entry = put_in(entry, [:consensus], %{})
            entry = put_in(entry, [:consensus, :score], Float.round(score, 3))
            entry = put_in(entry, [:consensus, :mut_hash], Base58.encode(mut_hash))
        end
    end
end

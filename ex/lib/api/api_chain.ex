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

    def format_entry_for_client(entry) do
        entry = Map.put(entry, :tx_count, length(entry.txs))
        entry = Map.drop(entry, [:header, :signature, :txs])
        {_, entry} = pop_in(entry, [:header_unpacked, :txs_hash])
        entry = put_in(entry, [:hash], Base58.encode(entry.hash))
        entry = put_in(entry, [:header_unpacked, :dr], Base58.encode(entry.header_unpacked.dr))
        entry = put_in(entry, [:header_unpacked, :vr], Base58.encode(entry.header_unpacked.vr))
        entry = put_in(entry, [:header_unpacked, :prev_hash], Base58.encode(entry.header_unpacked.prev_hash))
        entry = put_in(entry, [:header_unpacked, :signer], Base58.encode(entry.header_unpacked.signer))
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
            Map.drop(c, [:mask])
        end)
    end
end
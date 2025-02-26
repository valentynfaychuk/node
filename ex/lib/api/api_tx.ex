defmodule API.TX do
    def get(tx_id) do
        Consensus.chain_tx(tx_id)
    end

    def get_by_entry(entry_hash) do
        case Fabric.entry_by_hash(entry_hash) do
            nil -> nil
            %{txs: txs} -> Enum.map(txs, & TX.unpack(&1))
        end
    end

    def get_by_address(pk) do
    end
end
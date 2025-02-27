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

    def submit(tx_packed) do
        %{error: error} = TX.validate(tx_packed)
        if error == :ok do
            TXPool.insert(tx_packed)
            NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
            %{error: :ok}
        else
            %{error: error}
        end
    end
end
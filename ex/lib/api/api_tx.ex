defmodule API.TX do
    def get(tx_id) do
        tx_id = if byte_size(tx_id) != 32, do: Base58.decode(tx_id), else: tx_id
        Consensus.chain_tx(tx_id)
        |> format_tx_for_client()
    end

    def get_by_entry(entry_hash) do
        entry_hash = if byte_size(entry_hash) != 32, do: Base58.decode(entry_hash), else: entry_hash
        case Fabric.entry_by_hash(entry_hash) do
            nil -> nil
            %{txs: txs} -> Enum.map(txs, & format_tx_for_client(TX.unpack(&1)))
        end
    end

    def get_by_address(pk) do
        txs = get_by_address_sent(pk) ++ get_by_address_recv(pk)
        Enum.sort_by(txs, & &1.tx.nonce)
    end

    def get_by_address_sent(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk

        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get_prefix("#{pk}:", %{db: db, cf: cf.tx_account_nonce})
        |> Enum.map(fn {nonce, txid}->
            API.TX.get(txid)
            |> Map.put(:metadata, %{tx_event: :sent})
        end)
    end

    def get_by_address_recv(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk

        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        RocksDB.get_prefix("#{pk}:", %{db: db, cf: cf.tx_receiver_nonce})
        |> Enum.map(fn {nonce, txid}->
            API.TX.get(txid)
            |> Map.put(:metadata, %{tx_event: :recv})
        end)
    end

    def submit(tx_packed) do
        %{error: error} = TX.validate(tx_packed)
        if error == :ok do
            if tx_packed =~ "deploy" do
                txu = TX.unpack(tx_packed)
                action = hd(txu.tx.actions)
                if action.contract == "Contract" and action.function == "deploy" do
                    case BIC.Contract.validate(List.first(action.args)) do
                        %{error: :ok} ->
                            TXPool.insert(tx_packed)
                            NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
                            %{error: :ok}
                        error -> error
                    end
                else
                    TXPool.insert(tx_packed)
                    NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
                    %{error: :ok}
                end
            else
                TXPool.insert(tx_packed)
                NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
                %{error: :ok}
            end
        else
            %{error: error}
        end
    end

    def format_tx_for_client(tx) do
        tx = Map.drop(tx, [:tx_encoded])
        tx = Map.put(tx, :signature, Base58.encode(tx.signature))
        tx = Map.put(tx, :hash, Base58.encode(tx.hash))
        tx = put_in(tx, [:tx, :signer], Base58.encode(tx.tx.signer))
        actions = Enum.map(tx.tx.actions, fn(a)->
            args = Enum.map(a.args, fn(arg)->
                cond do
                    !is_binary(arg) or Util.ascii?(arg) -> arg
                    true -> Base58.encode(arg)
                end
            end)
            Map.put(a, :args, args)
        end)
        tx = put_in(tx, [:tx, :actions], actions)
    end
end

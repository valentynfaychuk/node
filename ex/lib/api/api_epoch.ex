defmodule API.Epoch do
    def set_emission_address(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
        sk = Application.fetch_env!(:ama, :trainer_sk)
        tx_packed = TX.build(sk, "Epoch", "set_emission_address", [pk])
        TXPool.insert(tx_packed)
        NodeGen.broadcast(:txpool, :trainers, [[tx_packed]])
    end

    def get_emission_address() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        get_emission_address(pk)
    end

    def get_emission_address(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
        API.ContractState.get("bic:epoch:emission_address:#{pk}")
        |> Base58.encode()
    end
end
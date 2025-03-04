defmodule API.Peer do
    def trainers() do
        Consensus.trainers_for_height(Consensus.chain_height()+1)
        |> Enum.map(fn(pk)->
            p = NodePeers.by_pk(pk)
            inSlot = Consensus.trainer_for_slot(Consensus.chain_height()+1, Consensus.chain_height()+1) == pk
            if !!p and NodePeers.is_online(p) do
                [Base58.encode(pk), p[:version], true, inSlot, p[:latency], get_in(p, [:temporal, :header_unpacked, :height]), get_in(p, [:rooted, :header_unpacked, :height])]
            else
                [Base58.encode(pk), p[:version], false, inSlot]
            end
        end)
    end

    def version_ratio() do
        trainers()
        |> Enum.reduce(%{}, fn([_pk, version | _], acc)->
            Map.put(acc, version, Map.get(acc, version, 0) + 1)
        end)
        |> Enum.sort_by(& elem(&1, 1), :desc)
    end

    def all() do
        NodePeers.all
        |> Enum.map(& [
            &1[:version],&1[:latency],Base58.encode(&1[:pk]),
            get_in(&1, [:temporal, :header_unpacked, :height]),
            get_in(&1, [:rooted, :header_unpacked, :height]),
        ])
        |> Enum.sort(:desc)
    end
end
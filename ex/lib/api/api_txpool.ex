defmodule API.TXPool do
    def get() do
        :ets.foldl(fn({_key, txu}, acc)->
            acc ++ [txu]
        end, [], TXPool)
    end

    def get(pk) do
        pk = if byte_size(pk) != 48, do: Base58.decode(pk), else: pk
        :ets.foldl(fn({_key, txu}, acc)->
            if txu.tx.signer == pk do
                acc ++ [txu]
            else
                acc
            end
        end, [], TXPool)
    end

    def stats() do
        :ets.foldl(fn({_key, txu}, acc)->
            Map.put(acc, txu.tx.signer, Map.get(acc, txu.tx.signer, 0) + 1)
        end, %{}, TXPool)
        |> Enum.sort_by(& elem(&1,1), :desc)
    end
end

defmodule BLS12AggSig do
    def new(trainers, pk, signature) do
        index_of_trainer = Util.index_of(trainers, pk)

        mask = <<0::size(length(trainers))>>
        mask = Util.set_bit(mask, index_of_trainer)

        %{mask: mask, aggsig: signature}
    end

    def add(m = %{mask: mask, aggsig: aggsig}, trainers, pk, signature) do
        index_of_trainer = Util.index_of(trainers, pk)

        if Util.get_bit(mask, index_of_trainer) do m else
            trainers_signed = unmask_trainers(trainers, mask)
            cond do
                trainers_signed == [] -> throw %{error: :no_one_signed_call_new_first}
                length(trainers_signed) == 1 ->
                    aggsig = BlsEx.aggregate_signatures!([aggsig, signature], [hd(trainers_signed), pk])
                    mask = Util.set_bit(mask, index_of_trainer)
                    %{mask: mask, aggsig: aggsig}

                true ->
                    apk = BlsEx.aggregate_public_keys!(trainers_signed)
                    aggsig = BlsEx.aggregate_signatures!([aggsig, signature], [apk, pk])
                    mask = Util.set_bit(mask, index_of_trainer)
                    %{mask: mask, aggsig: aggsig}
            end
        end
    end

    #TODO: optimize walking with mask
    def unmask_trainers(trainers, mask) do
        length = bit_size(mask)
        Enum.reduce(0..length-1, [], fn(index, acc)->
            if !Util.get_bit(mask, index) do acc else
                acc ++ [Enum.at(trainers, index)]
            end
        end)
    end
end
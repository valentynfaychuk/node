defmodule BIC.Epoch do
    import ConsensusKV

    @epoch_emission_base BIC.Coin.to_flat(1_000_000)
    @epoch_interval 100_000

    def epoch_emission(_epoch, acc \\ @epoch_emission_base)
    def epoch_emission(0, acc) do acc end
    def epoch_emission(epoch, acc) do
        sub = div(acc * 333, 1000000)
        epoch_emission(epoch - 1, acc - sub)
    end

    def circulating_without_burn(_epoch, _acc \\ 0)
    def circulating_without_burn(0, acc) do acc end
    def circulating_without_burn(epoch, acc) do
        circulating_without_burn(epoch - 1, acc + epoch_emission(epoch))
    end

    def circulating(epoch) do circulating_without_burn(epoch) - BIC.Coin.burn_balance() end

    def call(:submit_sol, env, [sol]) do
        if kv_exists("bic:epoch:solutions:#{sol}"), do: throw(%{error: :sol_exists})
        
        if !BIC.Sol.verify(sol), do: throw(%{error: :invalid_sol})

        su = BIC.Sol.unpack(sol)
        if su.epoch != Entry.epoch(env.entry), do: throw(%{error: :invalid_epoch})

        if !kv_get("bic:epoch:pop:#{su.pk}") do
            if !BlsEx.verify?(su.pk, su.pop, su.pk, BLS12AggSig.dst_pop()), do: throw %{error: :invalid_pop}
            kv_put("bic:epoch:pop:#{su.pk}", su.pop)
        end
        kv_put("bic:epoch:solutions:#{sol}", su.pk)
    end

    def call(:set_emission_address, env, [address]) do
        if byte_size(address) != 48, do: throw(%{error: :invalid_address_pk})
        kv_put("bic:epoch:emission_address:#{env.txu.tx.signer}", address)
    end

    def next(env) do
        epoch_fin = Entry.epoch(env.entry)
        epoch_next = epoch_fin + 1
        top_x = cond do
            epoch_next > 3 -> 19
            true -> 9
        end

        leaders = kv_get_prefix("bic:epoch:solutions:")
        |> Enum.reduce(%{}, fn({_sol, pk}, acc)->
            Map.put(acc, pk, Map.get(acc, pk, 0) + 1)
        end)
        |> Enum.sort_by(& elem(&1,1), :desc)
        
        trainers = kv_get("bic:epoch:trainers:#{epoch_fin}")
        trainers_to_recv_emissions = leaders
        |> Enum.filter(& elem(&1,0) in trainers)
        |> Enum.take(top_x)

        total_sols = Enum.reduce(trainers_to_recv_emissions, 0, & &2 + elem(&1,1))
        Enum.each(trainers_to_recv_emissions, fn({trainer, trainer_sols})->
            coins = div(trainer_sols * epoch_emission(epoch_fin), total_sols)

            emission_address = kv_get("bic:epoch:emission_address:#{trainer}")
            if emission_address do
                kv_increment("bic:coin:balance:#{emission_address}", coins)
            else
                kv_increment("bic:coin:balance:#{trainer}", coins)
            end
        end)

        kv_clear("bic:epoch:solutions:")

        new_trainers = if length(leaders) == 0 do trainers else
            leaders = leaders
            |> Enum.take(top_x)
            |> Enum.map(fn{pk, _}-> pk end)
            
            #TODO: Even may not reach consensus in netsplit/malicicous net
            #TODO: but doubleslotting can potentially break other logic
            #if rem(length(leaders), 2) == 0 do
            #   leaders ++ [hd(leaders)]
            #else
            #   leaders
            #end
        end
        new_trainers = Enum.shuffle(new_trainers)
        kv_put("bic:epoch:trainers:#{epoch_next}", new_trainers)
        if epoch_next > 3 do
            kv_put("bic:epoch:trainers:height:#{env.entry.header_unpacked.height+1}", new_trainers)
        end
    end

    def call(:slash_trainer, env, [bin]) do
        cur_epoch = Entry.epoch(env.entry)
        <<"slash_trainer", epoch::32-little, malicious_pk::48-binary, signature::96-binary, bitmasksize::32-little, mask::size(bitmasksize)>> = bin
        mask = <<mask::size(bitmasksize)>>

        if cur_epoch != epoch, do: throw(%{error: :invalid_epoch})

        trainers = kv_get("bic:epoch:trainers:#{cur_epoch}")
        if malicious_pk not in trainers, do: throw(%{error: :invalid_trainer_pk})

        # 75% vote
        signers = BLS12AggSig.unmask_trainers(trainers, mask)
        consensus_pct = length(signers) / length(trainers)
        if consensus_pct < 0.75, do: throw %{error: :invalid_amount_of_signatures}

        apk = BlsEx.aggregate_public_keys!(signers)
        msg = <<"slash_trainer", cur_epoch, malicious_pk>>
        if !BlsEx.verify?(apk, signature, msg, BLS12AggSig.dst_motion()), do: throw %{error: :invalid_signature}

        # slash sols
        kv_get_prefix("bic:epoch:solutions:")
        |> Enum.each(fn({sol, sol_pk})->
            if malicious_pk == sol_pk do
                kv_delete("bic:epoch:solutions:#{sol}")
            end
        end)

        new_trainers = trainers -- [malicious_pk]
        kv_put("bic:epoch:trainers:#{cur_epoch}", new_trainers)
        kv_put("bic:epoch:trainers:height:#{env.entry.header_unpacked.height}", new_trainers)
    end

    @doc """
    def call(:slash_double_entry, env, [entrya, entryb]) do
        %{trainer: trainera, height: heighta, hash: hasha} = entrychain.validate_entry(entrya)
        %{trainer: trainerb, height: heightb, hash: hashb} = entrychain.validate_entry(entryb)

        if trainera != trainerb, do: throw(%{error: :different_signer})
        if heighta != heightb, do: throw(%{error: :different_height})
        if trunc(heighta/100_000) != trunc(env.height/100_000), do: throw(%{error: :stale_chain_epoch})
        if hasha == hashb, do: throw(%{error: :same_entry})

        kv_delete(:trainers, trainera)
        kv_delete_match(:solutions, {:_, %{trainer: trainera}})
    end
    """
end
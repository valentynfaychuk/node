defmodule UPOW do
    def compute_for(epoch, trainer, pop, computor, segment_vr, itrs \\ 30)
    def compute_for(epoch, trainer, pop, computor, segment_vr, 0), do: nil
    def compute_for(epoch, trainer, pop, computor, segment_vr, itrs) do
        {hash, sol} = branch_sol(epoch, trainer, pop, computor, segment_vr)
        valid = BIC.Sol.verify_hash(epoch, hash)
        if valid do
            sol
        else
            compute_for(epoch, trainer, pop, computor, segment_vr, itrs - 1)
        end
    end

    def branch_sol(epoch, trainer, pop, computor, segment_vr) do
        cond do
            epoch >= 1 -> UPOW1.tensor_math(epoch, trainer, pop, computor, segment_vr)
            true -> UPOW0.tensor_math(epoch, trainer, pop, computor)
        end
    end

    def test() do
        Enum.reduce(1..10000, <<0xff>>, fn(itr, best)->
            IO.inspect {"pow #{itr} so far best sol", best}

            pk = Application.fetch_env!(:ama, :trainer_pk)
            pop = Application.fetch_env!(:ama, :trainer_pop)
            epoch = Consensus.DB.chain_epoch()

            {hash, sol} = branch_sol(epoch, <<>>, pk, pop, pk)
            if hash < best do
                sol
            else
                best
            end
        end)
    end
end

defmodule UPOW0 do
    #1024 #262144
    def tensormath(epoch, trainer, pop, computor) do
        nonce = :crypto.strong_rand_bytes(32)
        sol_seed = <<epoch::32-little, trainer::binary, pop::binary, computor::binary, nonce::binary>>
        sol_seed = sol_seed <> :binary.copy(<<0>>, 256 - byte_size(sol_seed))
        {calculate(sol_seed), sol_seed}
    end

    def calculate(sol_seed) do
        b = Blake3.new()
        Blake3.update(b, sol_seed)
        tensor = Enum.reduce(0..1023, %{}, fn(idx, acc)->
            acc = Map.put(acc, idx, Blake3.finalize_xof(b, 1024))
            Blake3.update(b, Blake3.finalize(b))
            acc
        end)
        random_walk_bin = Blake3.finalize_xof(b, 1024*8*2)
        walk_mul(random_walk_bin, tensor)
    end

    def walk_mul(<<>>, tensor) do
        b = Blake3.new()
        tensor = Enum.each(0..1023, fn(idx)->
            Blake3.update(b, tensor[idx])
        end)
        Blake3.finalize(b)
    end

    def walk_mul(<<index::16-little, rest::binary>>, tensor) do
        index = rem(index, 1024)
        {_row, new_row} = Enum.reduce(0..1023, {tensor[index], <<>>}, fn(idx, {row, new_row})->
          element = :binary.at(row, idx)
            {row, <<new_row::binary, element*element>>}
        end)
        tensor = Map.put(tensor, index, new_row)
        walk_mul(rest, tensor)
    end
end

defmodule UPOW1 do
    #1024 #262144
    def tensormath(epoch, trainer, pop, computor, segment_vr) do
        nonce = :crypto.strong_rand_bytes(16)
        sol_seed = <<epoch::32-little, trainer::binary, pop::binary, computor::binary, segment_vr::binary, nonce::binary>>
        sol_seed = sol_seed <> :binary.copy(<<0>>, 256 - byte_size(sol_seed))
        {calculate(sol_seed), sol_seed}
    end

    def calculate(sol_seed) do
        b = Blake3.new()
        Blake3.update(b, sol_seed)
        tensor = Enum.reduce(0..(256-1), %{}, fn(idx, acc)->
            acc = Map.put(acc, idx, Blake3.finalize_xof(b, 256))
            Blake3.update(b, Blake3.finalize(b))
            acc
        end)
        random_walk_bin = Blake3.finalize_xof(b, 512*8*2)
        walk_mul(random_walk_bin, tensor)
    end

    def walk_mul(<<>>, tensor) do
        b = Blake3.new()
        tensor = Enum.each(0..(256-1), fn(idx)->
            Blake3.update(b, tensor[idx])
        end)
        Blake3.finalize(b)
    end

    def walk_mul(<<index::16-little, rest::binary>>, tensor) do
        index = rem(index, 256)
        {_row, new_row} = Enum.reduce(0..(256-1), {tensor[index], <<>>}, fn(idx, {row, new_row})->
          element = :binary.at(row, idx)
            {row, <<new_row::binary, element*element>>}
        end)
        tensor = Map.put(tensor, index, new_row)
        walk_mul(rest, tensor)
    end
end

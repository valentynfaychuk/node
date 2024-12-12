defmodule UPOW do
	#1024 #262144
	def calculate(nonce) do
		b = Blake3.new()
		Blake3.update(b, nonce)
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

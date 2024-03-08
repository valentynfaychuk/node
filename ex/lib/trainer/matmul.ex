defmodule Ama.Trainer do
  #Frievalds   this one is broken! DONT USE
  def verify(a, b, result, iterations \\ 10) do
    Enum.all?(1..iterations, fn _ ->
      r = Enum.map(1..length(List.first(b)), fn _ -> Enum.random(0..1) end)
      left = multiply_matrices(a, multiply_matrices(b, [r]))
      right = multiply_matrices(result, [r])
      Enum.at(left, 0) == Enum.at(right, 0)
    end)
  end

  def multiply_matrices(a, b) do
    b_transposed = transpose(b)
    for row <- a do
      for col <- b_transposed do
        Enum.zip(row, col)
        |> Enum.map(fn {x, y} -> x * y end)
        |> Enum.sum()
      end
    end
  end

  def transpose(matrix) do
    matrix
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  def sum_elements(matrix) do
    Enum.map(matrix, fn row -> Enum.sum(row) end)
    |> Enum.sum()
  end

  def seed_matrix(pubkey, nonce) do
    a = [1000,1000]
    b = [1000,1]
    :blake3_stream_X_bytes_to_fill_matrixes
    :matmul_a_b
    :verify_via_frievalds
    :if_sum_gt_10000000_get_a_coin
  end
end

defmodule SolDifficulty do
  @target_sols_epoch 380_000

  @tol_num 1
  @tol_den 10

  @max_step_down 3
  @max_step_up   2
  @up_slowdown   2

  @diff_min_bits 20
  @diff_max_bits 64

  defp clamp_bits(b), do: b |> max(@diff_min_bits) |> min(@diff_max_bits)

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp ilog2_floor(n) when n >= 1, do: do_ilog2(n, 0)
  defp do_ilog2(1, acc), do: acc
  defp do_ilog2(n, acc), do: do_ilog2(div(n, 2), acc + 1)

  defp ceil_log2_ratio(a, b) when a <= b, do: 0
  defp ceil_log2_ratio(a, b) do
    d0 = ilog2_floor(a) - ilog2_floor(b)
    if :erlang.bsl(b, d0) >= a, do: d0, else: d0 + 1
  end

  def next(prev_bits, sols) do
    target = @target_sols_epoch

    lo = max(1, div(target * (@tol_den - @tol_num) + div(@tol_den, 2), @tol_den))
    hi =        div(target * (@tol_den + @tol_num) + div(@tol_den, 2), @tol_den)

    cond do
      sols == 0 ->
        clamp_bits(prev_bits - min(@max_step_down, 3))

      sols > hi ->
        raw = ceil_log2_ratio(sols, target)
        delta = raw
        |> ceil_div(@up_slowdown)
        |> min(@max_step_up)
        |> max(1)
        clamp_bits(prev_bits + delta)

      sols < lo ->
        delta = ceil_log2_ratio(target, max(sols, 1))
        |> min(@max_step_down)
        |> max(1)
        clamp_bits(prev_bits - delta)

      true ->
        prev_bits
    end
  end
end

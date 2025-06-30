defmodule VanityGenerator do
  def go(prefix, skip_leading \\ true, case_insensitive \\ true, max_tries \\ 10000, iteration \\ 0) do
    iteration = iteration + 1
    sk = :crypto.strong_rand_bytes(64)
    full_key = BlsEx.get_public_key!(sk) |> Base58.encode()
    key = if skip_leading do <<_, rest::binary>> = full_key; rest else full_key end
    <<key_slice::binary-size(byte_size(prefix)), _::binary>> = key
    if rem(iteration, 1000) == 0 do
      IO.inspect {prefix, key_slice, key}
    end
    cond do
      iteration > max_tries -> nil
      case_insensitive and String.upcase(key_slice) == String.upcase(prefix) -> {full_key, Base58.encode(sk)}
      key_slice == prefix -> {full_key, Base58.encode(sk)}
      true -> go(prefix, skip_leading, case_insensitive, max_tries, iteration)
    end
  end
end

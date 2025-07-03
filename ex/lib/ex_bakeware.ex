defmodule Ama.Bakeware do
    use Bakeware.Script
    require Logger

    @impl Bakeware.Script
    def main(args) do
        arg0 = List.first(args)
        cond do
          arg0 == "buildtx" ->
            Process.sleep(500)
            IO.puts ""

            ["buildtx", contract, func, args | rest] = args
            contract = if Base58.likely(contract) do Base58.decode(contract) else contract end
            sk = Application.fetch_env!(:ama, :trainer_sk)
            {args, []} = Code.eval_string(args)
            [attach_symbol, attach_amount] = if length(rest) != 2 do [nil,nil] else
              [attach_symbol, attach_amount] = rest
            end
            packed_tx = TX.build(sk, contract, func, args, nil, attach_symbol, attach_amount)
            IO.puts Base58.encode(packed_tx)
            :erlang.halt()

          arg0 == "deploytx" ->
            Process.sleep(500)
            IO.puts ""

            ["deploytx", wasmpath] = args
            sk = Application.fetch_env!(:ama, :trainer_sk)
            wasmbytes = File.read!(wasmpath)
            error = BIC.Contract.validate(wasmbytes)
            if error[:error] != :ok do
              IO.puts(:stderr, inspect(error))
              :erlang.halt()
            end
            packed_tx = TX.build(sk, "Contract", "deploy", [wasmbytes])
            IO.puts Base58.encode(packed_tx)
            :erlang.halt()

          arg0 == "getpk" ->
            Process.sleep(500)
            IO.puts ""

            ["getpk", path] = args
            sk = File.read!(path) |> String.trim()
            pk = BlsEx.get_public_key!(Base58.decode(sk))
            IO.puts Base58.encode(pk)
            :erlang.halt()

          true ->
            Ama.start(nil, [])
            receive do end
            0
        end
    end
end

defmodule RPC.API do
  def get(path) do
    url = Application.fetch_env!(:ama, :rpc_url)
    {:ok, %{status_code: 200, body: body}} = :comsat_http.get(url <> path, %{},
      %{ssl_options: [{:server_name_indication, ~c"#{URI.parse(url).host}"}, {:verify, :verify_none}]})
    JSX.decode!(body, labels: :attempt_atom)
  end

  defmodule Wallet do
    def transfer(seed64, receiver, amount_float, symbol \\ "AMA") do
      receiver = if byte_size(receiver) != 48, do: Base58.decode(receiver), else: receiver
      receiver_b58 = Base58.encode(receiver)
      if !BlsEx.validate_public_key(receiver) and receiver != BIC.Coin.burn_address() do
        IO.inspect {"sending #{amount_float} AMA to invalid public key", receiver_b58}
        %{error: :invalid_public_key, pk: receiver_b58}
      else
        txu = API.Wallet.transfer(seed64, receiver, amount_float, symbol, false)
        RPC.API.get("/api/tx/submit_and_wait/#{Base58.encode(txu |> TX.pack())}?finality=true")
      end
    end

    def transfer_bulk(seed64, receiver_amount_list) do
      Enum.map(receiver_amount_list, fn
        {receiver, amount_float} ->
          receiver = if byte_size(receiver) != 48, do: Base58.decode(receiver), else: receiver
          receiver_b58 = Base58.encode(receiver)
          if !BlsEx.validate_public_key(receiver) and receiver != BIC.Coin.burn_address() do
            IO.inspect {"sending #{trunc(amount_float)} AMA to invalid public key", receiver_b58}
            %{error: :invalid_public_key, pk: receiver_b58}
          else
            IO.inspect {"sending #{trunc(amount_float)} AMA to ", receiver_b58}
            txu = API.Wallet.transfer(seed64, receiver, amount_float, "AMA", false)
            RPC.API.get("/api/tx/submit_and_wait/#{Base58.encode(txu |> TX.pack())}?finality=true")
          end

        {receiver, amount_float, symbol} ->
          receiver = if byte_size(receiver) != 48, do: Base58.decode(receiver), else: receiver
          receiver_b58 = Base58.encode(receiver)
          if !BlsEx.validate_public_key(receiver) and receiver != BIC.Coin.burn_address() do
            IO.inspect {"sending #{amount_float} AMA to invalid public key", receiver_b58}
            %{error: :invalid_public_key, pk: receiver_b58}
          else
            IO.inspect {"sending #{amount_float} #{symbol} to ", receiver_b58}
            txu = API.Wallet.transfer(seed64, receiver, amount_float, symbol, false)
            RPC.API.get("/api/tx/submit_and_wait/#{Base58.encode(txu |> TX.pack())}?finality=true")
          end
      end)
    end

    def balance(pk, symbol \\ "AMA") do
      RPC.API.get("/api/wallet/balance/#{pk}/#{symbol}")
    end
  end

  defmodule Chain do
    def tx(txid) do
      RPC.API.get("/api/chain/tx/#{txid}")
    end
  end
end

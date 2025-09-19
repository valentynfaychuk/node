defmodule RPC.API do
  def get(path) do
    url = Application.fetch_env!(:ama, :rpc_url)
    {:ok, %{status_code: 200, body: body}} = :comsat_http.get(url <> path, %{},
      %{ssl_options: [{:server_name_indication, '#{URI.parse(url).host}'}, {:verify, :verify_none}]})
    JSX.decode!(body, labels: :attempt_atom)
  end

  defmodule Wallet do
    def transfer(seed64, receiver, amount_float, symbol \\ "AMA") do
      tx_packed = API.Wallet.transfer(seed64, receiver, amount_float, symbol, false)
      RPC.API.get("/api/tx/submit/#{Base58.encode(tx_packed)}")
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

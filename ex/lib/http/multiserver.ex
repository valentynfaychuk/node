defmodule Ama.MultiServer do
    def init(state) do
        receive do
            :socket_ack -> :ok
        after 3000 -> throw(:no_socket_passed) end

        state = Map.put(state, :request, %{buf: <<>>})
        :ok = :inet.setopts(state.socket, [{:active, :once}])
        loop_http(state)
    end

    def loop_http(state) do
        #IO.inspect "hooked"
        receive do
            {:tcp, socket, bin} ->
                request = %{state.request | buf: state.request.buf <> bin}
                case Photon.HTTP.Request.parse(request) do
                    {:partial, request} ->
                        state = put_in(state, [:request], request)
                        :inet.setopts(socket, [{:active, :once}])
                        loop_http(state)
                    request ->
                        state = put_in(state, [:request], request)
                        cond do
                            request[:step] in [:next, :body] ->
                                state = handle_http(state)
                                if request.headers["connection"] in ["close", "upgrade"] do
                                    :gen_tcp.shutdown(socket, :write)
                                else
                                    {_, state} = pop_in(state, [:request, :step])
                                    :inet.setopts(socket, [{:active, :once}])
                                    loop_http(state)
                                end

                            true ->
                                :inet.setopts(socket, [{:active, :once}])
                                loop_http(state)
                        end
                end

            {:tcp_closed, socket} -> :closed
            m -> IO.inspect("MultiServer: #{inspect m}")
        end
    end

    def quick_reply(state, reply, status_code \\ 200) do
        :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(state.request, status_code, %{}, reply))
        state
    end

    def moveme(nil) do
        %{
        }
    end

    def build_dashboard(state) do
        file = Application.app_dir(:ama, "priv/index.html")
        bin = File.read!(file)

        inject = moveme(nil)
        String.replace(bin,"{replace:\"me\"}", JSX.encode!(inject))
    end

    def handle_http(state) do
        r = state.request
        IO.inspect r.path

        cond do
            r.method in ["OPTIONS", "HEAD"] ->
                :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(state.request, 200, %{}, ""))
                state
             
            #r.headers["upgrade"] == "websocket" and String.starts_with?(r.path, "/ws/panel") ->
            #    Shep.WSPanel.init(state)
            r.method == "GET" and r.path == "/favicon.ico" ->
                quick_reply(state, "")

            r.method == "GET" and String.starts_with?(r.path, "/api/chain/tip") ->
                result = API.Chain.entry_tip()
                quick_reply(state, result)

            r.method == "GET" and String.starts_with?(r.path, "/api/chain/height/") ->
                height = String.replace(r.path, "/api/chain/height/", "")
                |> :erlang.binary_to_integer()
                result = API.Chain.by_height(height)
                quick_reply(state, result)

            r.method == "GET" and String.starts_with?(r.path, "/api/chain/height_with_txs/") ->
                height = String.replace(r.path, "/api/chain/height_with_txs/", "")
                |> :erlang.binary_to_integer()
                result = API.Chain.by_height_with_txs(height)
                quick_reply(state, result)

            r.method == "GET" and String.starts_with?(r.path, "/api/chain/tx/") ->
                txid = String.replace(r.path, "/api/chain/tx/", "")
                result = API.TX.get(txid)
                quick_reply(state, result)

            r.method == "GET" and String.starts_with?(r.path, "/api/chain/txs_in_entry/") ->
                entry_hash = String.replace(r.path, "/api/chain/txs_in_entry/", "")
                result = API.TX.get_by_entry(entry_hash)
                quick_reply(state, %{error: :ok, txs: result})

            r.method == "GET" and String.starts_with?(r.path, "/api/wallet/balance/") ->
                pk = String.replace(r.path, "/api/wallet/balance/", "")
                balance = API.Wallet.balance(pk)
                quick_reply(state, %{error: :ok, balance: balance})

            r.method == "POST" and String.starts_with?(r.path, "/api/tx/submit") ->
                {r, tx_packed} = Photon.HTTP.read_body_all_json(state.socket, r)
                result = API.TX.submit(tx_packed)
                quick_reply(state, result)
            r.method == "GET" and String.starts_with?(r.path, "/api/tx/submit/") ->
                tx_packed = String.replace(r.path, "/api/tx/submit/", "")
                result = API.TX.submit(Base58.decode(tx_packed))
                quick_reply(state, result)

            #r.method == "GET" ->
            #    bin = build_dashboard(state)
            #    quick_reply(state, bin)

            true ->
                quick_reply(state, %{error: :not_found}, 404)
        end
    end
end
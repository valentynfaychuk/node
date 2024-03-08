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

            r.method == "POST" and String.starts_with?(r.path, "/api/") ->
                {r, body} = Photon.HTTP.read_body_all_json(state.socket, r)
                quick_reply(state, "")


            r.method == "GET" ->
                bin = build_dashboard(state)
                quick_reply(state, bin)

            true ->
                reply = Photon.HTTP.Response.build_cors(state.request, 404, %{}, %{error: :not_found})
                quick_reply(state, reply)
        end
    end
end
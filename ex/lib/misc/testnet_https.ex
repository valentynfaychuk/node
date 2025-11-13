defmodule LocalCert do
  def ensure!(certfile, keyfile, hosts) do
    File.mkdir_p!(Path.dirname(certfile))
    if File.exists?(certfile) and File.exists?(keyfile), do: :ok, else: gen(hosts)
  end

  def gen(hosts \\ nil) do
    hosts = try do
      File.read!("/etc/hosts")
      |> String.split("\n")
      |> Enum.map(fn(string)->
        String.split(string, " ") |> List.last
      end)
      |> Enum.filter(& &1 != "" and !String.starts_with?(&1, "ip6-"))
    catch _,_ -> [] end
    # Key (you can switch to EC with X509.PrivateKey.new_ec(:prime256v1))
    priv = X509.PrivateKey.new_rsa(2048)

    # Subject Alt Names (DNS + IP)
    sans = for h <- hosts do
      case :inet.parse_address(String.to_charlist(h)) do
        {:ok, ip} -> {:iPAddress, ip}
        _ -> {:dNSName, h}
      end
    end

    subject = X509.RDNSequence.new("/CN=#{Enum.at(hosts, 0) || "localhost"}")

    cert =
      X509.Certificate.self_signed(
        priv,
        subject,
        template: :server,
        hash: :sha256,
        serial: serial = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned(),
        subject_alt_name: sans,
        key_usage: [:digitalSignature, :keyEncipherment],
        extended_key_usage: [:serverAuth]
      )


    %{
      cert_der: X509.Certificate.to_der(cert),
      # Use PKCS#8 (PrivateKeyInfo) so it works regardless of key type
      key_der: X509.PrivateKey.to_der(priv)
    }
  end
end

defmodule TestNetHTTPSProxy do
  use GenServer

  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def allowselfsigned(_, reason, state) do
    {:valid, state}
  end

  def init(state) do
    :erlang.send_after(0, self(), :accept)
    Logger.put_module_level(:ssl_alert, :error)

    #{:ok, ip} = :inet.parse_ipv4_address(~c"#{state[:ip] || "127.0.0.1"}")
    ip = state[:ip] || {127,0,0,1}
    ip_string = "#{elem(ip,0)}.#{elem(ip,1)}.#{elem(ip,2)}.#{elem(ip,3)}"
    port = state[:port] || 443

    :ok = :ssl.start()
    %{cert_der: cert_der, key_der: key_der} = LocalCert.gen()
    ssl_opts = [
      {:ip, ip},
      {:reuseaddr, true},
      {:cert, cert_der},
      {:key, {:RSAPrivateKey, key_der}},
      {:supported_groups, [:x25519, :secp256r1]},
      {:versions, [:"tlsv1.3", :"tlsv1.2"]},
      {:binary, true},
      {:active, false},
      #cb_info: {:gen_tcp, :tcp, :tcp_closed, :tcp_error},
      {:verify, :verify_none},
      {:fail_if_no_peer_cert, false},
      #{:verify_fun, {:allowselfsigned, []}}
    ]
    {:ok, listen_socket} = :ssl.listen(port, ssl_opts)

    state = Map.merge(state, %{listen_socket: listen_socket})
    {:ok, state}
  end

  def handle_info(:accept, state) do
    {:ok, ssl_socket} = :ssl.transport_accept(state.listen_socket)
    case :ssl.handshake(ssl_socket) do
      {:ok, ssl_socket} ->
        pid = :erlang.spawn(__MODULE__, :client_loop, [%{ssl_socket: ssl_socket}])
        :ok = :ssl.controlling_process(ssl_socket, pid)
      {:error, reason} ->
        :ssl.close(ssl_socket)
    end

    :erlang.send_after(1, self(), :accept)
    {:noreply, state}
  end

  def client_loop(state) do
    up_host = Application.fetch_env!(:ama, :http_ipv4)
    up_port = 80
    {:ok, up_socket} = :gen_tcp.connect(up_host, up_port, [:binary, active: false], 5_000)
    :ok = :ssl.setopts(state.ssl_socket, active: :once)
    :ok = :inet.setopts(up_socket, active: :once)
    client_loop_1(state.ssl_socket, up_socket)
  end
  def client_loop_1(ssl_socket, up_socket) do
    receive do
    {:ssl, ssl_socket, data} ->
        :ok = :gen_tcp.send(up_socket, data)
        :ok = :ssl.setopts(ssl_socket, active: :once)
        client_loop_1(ssl_socket, up_socket)
      {:tcp, up_socket, data} ->
        :ok = :ssl.send(ssl_socket, data)
        :ok = :inet.setopts(up_socket, active: :once)
        client_loop_1(ssl_socket, up_socket)
      {:ssl_closed, ssl_socket} -> :ssl.close(ssl_socket)
      msg -> IO.inspect( msg )
    after 60_000 -> nil end
  end
end

defmodule NodeGen do
  use GenServer

  def start_link(ip_tuple, port) do
    GenServer.start_link(__MODULE__, [ip_tuple, port], name: __MODULE__)
  end

  def init([ip_tuple, port]) do
    lsocket = listen(port, [{:ifaddr, ip_tuple}])
    ip = Tuple.to_list(ip_tuple) |> Enum.join(".")
    NodePeers.seed(ip)
    state = %{
      ip: ip, ip_tuple: ip_tuple, port: port, socket: lsocket,
      ns: NodeState.init()
    }
    :erlang.send_after(1000, self(), :tick)
    :erlang.send_after(1000, self(), :tick_ping)
    {:ok, state}
  end

  def listen(port, opts \\ []) do
    basic_opts = [
      {:active, :once},
      {:reuseaddr, true},
      {:reuseport, true}, #working in OTP26.1+
      :binary,
    ]
    {:ok, lsocket} = :gen_udp.open(port, basic_opts++opts)
    lsocket
  end



  def broadcast_ping() do
    :erlang.spawn(fn()->
      msg = NodeProto.ping()
      ips = NodePeers.all() |> Enum.map(& &1.ip)
      send(NodeGen, {:send_to_some, ips, NodeProto.pack_message(msg)})
    end)
  end

  def broadcast(:txpool, who, [txs_packed]) do
    :erlang.spawn(fn()->
      msg = NodeProto.txpool(txs_packed)
      ips = NodePeers.by_who(who)
      send(NodeGen, {:send_to_some, ips, NodeProto.pack_message(msg)})
    end)
  end

  def broadcast(:entry, who, [map]) do
    :erlang.spawn(fn()->
      msg = NodeProto.entry(map)
      ips = NodePeers.by_who(who)
      send(NodeGen, {:send_to_some, ips, NodeProto.pack_message(msg)})
    end)
  end

  def broadcast(:attestation_bulk, who, [attestations_packed]) do
    :erlang.spawn(fn()->
      msg = NodeProto.attestation_bulk(attestations_packed)
      ips = NodePeers.by_who(who)
      send(NodeGen, {:send_to_some, ips, NodeProto.pack_message(msg)})
    end)
  end

  def broadcast(:sol, who, [sol]) do
    :erlang.spawn(fn()->
      msg = NodeProto.sol(sol)
      ips = NodePeers.by_who(who)
      send(NodeGen, {:send_to_some, ips, NodeProto.pack_message(msg)})
    end)
  end



  def tick() do
    NodePeers.clear_stale()
  end

  def handle_info(msg, state) do
    case msg do
      :tick ->
        :erlang.send_after(1000, self(), :tick)
        tick()

      :tick_ping ->
        :erlang.send_after(500, self(), :tick_ping)
        broadcast_ping()

      {:send_to_some, peer_ips, packed_msg} ->
        #TODO: this leads to much less pkt loss
        Process.sleep(1)
        
        Enum.each(peer_ips, fn(ip)->
          {:ok, ip} = :inet.parse_address(~c'#{ip}')
          port = Application.fetch_env!(:ama, :udp_port)
          :ok = :gen_udp.send(state.socket, ip, port, packed_msg)
        end)

      {:udp, _socket, ip, _inportno, data} ->
        :erlang.spawn(fn()->
          case NodeProto.unpack_message(data) do
            %{error: :ok, msg: msg} ->
              peer_ip = Tuple.to_list(ip) |> Enum.join(".")
              #IO.puts IO.ANSI.red() <> inspect({:relay_from, ip, msg.op}) <> IO.ANSI.reset()
              peer = %{ip: peer_ip, signer: msg.signer, version: msg.version}
              NodeState.handle(msg.op, %{peer: peer}, msg)
            _ -> nil
          end
        end)
        :ok = :inet.setopts(state.socket, [{:active, :once}])

      {:handle_sync, op, innerstate, args} ->
        #TODO: ns dropped
        innerstate = Map.put(innerstate, :ns, state.ns)
        NodeState.handle(op, innerstate, args)

    end
    {:noreply, state}
  end
end

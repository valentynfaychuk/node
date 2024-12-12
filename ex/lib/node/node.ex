defmodule CRDTVans do
  def setup() do
	  path = Path.join([Application.fetch_env!(:serv, :work_folder), "mnesia_kv/"])
	  MnesiaKV.load(%{
			NODESys => %{key_type: :elixir_term},
			NODEChain => %{key_type: :elixir_term},
			NODETXPool => %{key_type: :elixir_term},
			NODEPeers => %{key_type: :elixir_term},
			CRDTLog => %{key_type: :elixir_term, index: [:node, :counter_global, :counter_local, :table]},
			CRDTUser => %{},
			CRDTUserCounter => %{key_type: :elixir_term},
	    }, %{path: path}
	  )
  end

  def merge(table, key, value) do
    json = op(:merge, table, key, value)
    proc_merge(json)
  end

  def increment(table, key, value) do
    json = op(:increment, table, key, value)
    proc_increment(json)
  end

  def op(op, table, key, value) do
	  node = Application.fetch_env!(:serv, :mnesia_kv_crdt_node)
	  counter_local = MnesiaKV.increment_counter(CRDTSys, CounterLocal, 1, nil)
	  counter_global = MnesiaKV.increment_counter(CRDTSys, CounterGlobal, 1, nil)
	  json = %{op: op,
	    table: table, key: key, value: value,
	  	node: node,
      counter_local: (counter_local - 1),
	    counter_global: (counter_global - 1),
	    nano: :os.system_time(:nanosecond)
	  }
	  MnesiaKV.merge(CRDTLog, {node, (counter_local - 1), (counter_global - 1)}, json)
	  send(CRDTVansListener, {:send_to_others, json})
		json
  end

  def proc(json) do
    key = {json.node, json.counter_local, json.counter_global}
    if !MnesiaKV.exists(CRDTLog, key) do
      MnesiaKV.increment_counter(CRDTSys, CounterGlobal, 1, nil)
      MnesiaKV.merge(CRDTLog, key, json)

      case json.op do
        :merge -> proc_merge(json)
        :increment -> proc_increment(json)
      end
    end

    #TODO; can prob move this inside the clause above with an init checker
    #coldstart can be broken otherwise
    sync_counter(json.node, json.counter_local)
  end

  def sync_counter(node, remotecounter) do
	  localcounter = MnesiaKV.get(CRDTSys, {node, CounterLocal}) || 0
	  if localcounter == remotecounter do
	    localcounter = MnesiaKV.increment_counter(CRDTSys, {node, CounterLocal}, 1, nil)

	    #fix holes
	    fn_fixholes = fn(fn_fixholes, ctr)->
	      if MnesiaKV.get_spec(CRDTLog, {node, ctr, :_}, %{nano: :'$1'}, :'$1') do
	        IO.inspect {CRDT, :fix_hole, node, ctr}
	        ctr = MnesiaKV.increment_counter(CRDTSys, {node, CounterLocal}, 1, nil)
	        fn_fixholes.(fn_fixholes, ctr)
	      end
	    end
	    fn_fixholes.(fn_fixholes, localcounter)
	  end
  end

  def proc_merge(json) do
    MnesiaKV.merge(json.table, json.key, json.value)
  end

  def proc_increment(json) do
    MnesiaKV.increment_counter(json.table, json.key, json.value)
  end
end

defmodule CRDTVansListener do
	#1280 max packet size
	#useless key to prevent udp noise
	def aes256key do
		<<108, 80, 102, 94, 44, 225, 200, 37, 227, 180, 114, 230, 230, 219,
		177, 28, 80, 19, 72, 13, 196, 129, 81, 216, 161, 36, 177, 212, 199, 6, 169, 26>>
	end

	def start_link(port, module) when is_atom(module) do
    pid = :erlang.spawn_link(__MODULE__, :init, [port, module])
    :erlang.register(__MODULE__, pid)
    {:ok, pid}
  end

  def start_link(ip, port, module) when is_atom(module) do
    pid = :erlang.spawn_link(__MODULE__, :init, [ip, port, module])
    :erlang.register(__MODULE__, pid)
    {:ok, pid}
  end

  def init(port, module) do
    lsocket = listen(port)
    state = %{ip: {0,0,0,0}, port: port, socket: lsocket, module: module}
    :erlang.send_after(0, self(), :tick)
    read_loop(state)
  end

  def init(ip, port, module) do
    ip = if !:erlang.is_tuple(ip), do: :inet.parse_address(~c'#{ip}') |> elem(1), else: ip
    lsocket = listen(port, [{:ifaddr, ip}])
    state = %{ip: ip, port: port, socket: lsocket, module: module}
    :erlang.send_after(0, self(), :tick)
    read_loop(state)
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

  def read_loop(state) do
  	receive do
      :tick ->
     	  node = Application.fetch_env!(:serv, :mnesia_kv_crdt_node)
        counter_local = MnesiaKV.get(CRDTSys, CounterLocal) || 0
        counter_global = MnesiaKV.get(CRDTSys, CounterGlobal) || 0

        json = %{op: :ping,
          node: node, counter_local: counter_local, counter_global: counter_global,
        	nano: :os.system_time(:nanosecond)}
        send(CRDTVansListener, {:send_to_others, json})

        #TODO: make it lower later
        :erlang.send_after(3000, self(), :tick)
        __MODULE__.read_loop(state)

      {:send_to_others, opmap} ->
        msg = prepare_msg(opmap)
        nodes = Application.fetch_env!(:serv, :mnesia_kv_crdt_othernodes)
        port = Application.fetch_env!(:serv, :mnesia_kv_crdt_port)
        IO.puts IO.ANSI.green() <> inspect({:relay_udp_to, nodes, opmap}) <> IO.ANSI.reset()
        Enum.each(nodes, fn(ip)->
          {:ok, ip} = :inet.parse_address(~c'#{ip}')
          :gen_udp.send(state.socket, ip, port, msg)
        end)
        __MODULE__.read_loop(state)

      {:udp, _socket, ip, _inportno, data} ->
        case try_decrypt_and_terms(data) do
          nil -> nil
          term ->
            IO.puts IO.ANSI.red() <> inspect({UDPData, json}) <> IO.ANSI.reset()
            proc(state, ip, term)
        end
        :ok = :inet.setopts(state.socket, [{:active, :once}])
        __MODULE__.read_loop(state)
    end
  end

  def prepare_msg(msg) do
	  json = :erlang.term_to_binary(msg)
	  iv = :crypto.strong_rand_bytes(12)
	  {ciphertext, tag} = encrypt(iv, json)
	  [tag, iv, ciphertext]
  end

  def proc(state, ip, term) do
    cond do
      term.op == :merge -> CRDTVans.proc(term)
      term.op == :increment -> CRDTVans.proc(term)
      term.op == :ping ->
        MnesiaKV.merge(NODESys, {term.node, Status}, %{nano: term.nano, last_ping: :os.system_time(:nanosecond)})
        localcounter = MnesiaKV.get(CRDTSys, {term.node, CounterLocal}) || 0
        remotecounter = json.counter_local
        if localcounter != remotecounter do
          IO.inspect {CRDT, :fetch_log_one, :sent_to, term.node, localcounter}
          mynode = Application.fetch_env!(:serv, :mnesia_kv_crdt_node)
          port = Application.fetch_env!(:serv, :mnesia_kv_crdt_port)
          msg = prepare_msg(%{op: :fetch_log_one, node: mynode, key: localcounter})
          :gen_udp.send(state.socket, ip, port, msg)
        end

      term.op == :fetch_log_one ->
        IO.inspect {CRDT, :fetch_log_one, :recv, term.key}
        port = Application.fetch_env!(:serv, :mnesia_kv_crdt_port)

        mynode = Application.fetch_env!(:serv, :mnesia_kv_crdt_node)
        msg = MnesiaKV.get_spec(CRDTLog, {mynode, term.key, :_}, :'$1', :'$1')
        if msg do
          msg = Map.drop(msg, [:uuid])
          IO.inspect msg
          msg = prepare_msg(msg)
          :gen_udp.send(state.socket, ip, port, msg)
        end
    end
  end

  def try_decrypt_and_terms(data) do
    try do
  	  <<tag::16-binary, iv::12-binary, ciphertext::binary>> = data
   	  text = decrypt(iv, tag, ciphertext)
      :erlang.binary_to_term(text)
    catch _,_ -> nil end
  end

  def encrypt(iv, text) do
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, aes256key(), iv, text, <<>>, 16, true)
    {ciphertext, tag}
  end

  def decrypt(iv, tag, ciphertext) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, aes256key(), iv, ciphertext, <<>>, tag, false)
  end
end

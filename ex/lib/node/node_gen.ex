defmodule NodeGen do
  use GenServer

  def start_link(ip_tuple, port) do
    GenServer.start_link(__MODULE__, [ip_tuple, port], name: __MODULE__)
  end

  def init([ip_tuple, port]) do
    lsocket = listen(port, [{:ifaddr, ip_tuple}])
    ip = Tuple.to_list(ip_tuple) |> Enum.join(".")
    seed_peers(ip)
    state = %{ip: ip, ip_tuple: ip_tuple, port: port, socket: lsocket}
    :erlang.send_after(1000, self(), :tick)
    :erlang.send_after(1000, self(), :ping)
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

  def seed_peers(my_ip) do
    seeds = Application.fetch_env!(:ama, :seednodes)
    nodes = Application.fetch_env!(:ama, :othernodes)
    filtered = Enum.uniq(seeds ++ nodes) -- [my_ip]
    Enum.each(filtered, fn(ip)->
      :ets.insert(NODEPeers, {ip, %{ip: ip, static: true}})
    end)
  end

  def random_peer() do
    peers_online()
    |> case do
      [] -> nil
      peers -> Enum.random(peers)
    end
  end

  def peers_clear_stale() do
    ts_m = :os.system_time(1000)
    peers = :ets.tab2list(NODEPeers)
    |> Enum.each(fn {key, v}->
      lp = v[:last_ping]
      #60 minutes
      if !v[:static] and !!lp and ts_m > lp+(1_000*60*60) do
        :ets.delete(NODEPeers, key)
      end
    end)
  end

  def peers() do
    peers = :ets.tab2list(NODEPeers)
    |> Enum.map(& elem(&1,1))
  end

  def peers_online() do
    ts_m = :os.system_time(1000)
    peers = :ets.tab2list(NODEPeers)
    |> Enum.reduce([], fn ({key, v}, acc)->
      lp = v[:last_ping]
      if !!lp and ts_m - lp <= 3_000 do
        acc ++ [v]
      else
        acc
      end
    end)
  end

  def broadcast_ping() do
    tip = Consensus.chain_tip_entry()
    msg = %{op: "ping", entry_height: tip.header_unpacked.height, entry_hash: tip.hash}
    send(NodeGen, {:send_to_others, msg})
  end

  def broadcast_tx(tx_packed) do
    msg = %{op: "txpool", tx_packed: tx_packed}
    send(NodeGen, {:send_to_others, msg})
  end

  def broadcast_entry(entry) do
    msg = %{op: "entry", entry_packed: Entry.pack(entry)}
    send(NodeGen, {:send_to_others, msg})
  end

  def broadcast_attestation(attestation) do
    msg = %{op: "attestation", attestation_packed: Attestation.pack(attestation)}
    send(NodeGen, {:send_to_others, msg})
  end

  def broadcast_need_attestation(entry) do
    msg = %{op: "need_attestation", entry_hash: entry.hash}
    send(NodeGen, {:send_to_others, msg})
  end

  def broadcast_sol(sol) do
    msg = %{op: "sol", sol: sol}
    send(NodeGen, {:send_to_others, msg})
  end

  def send_entry_to_peer(socket, peer, height) do
    entries = Fabric.entries_by_height(height)
    Enum.each(entries, fn(entry)->
      msg = %{op: "entry", entry_packed: Entry.pack(entry)}

      pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
      msg = if pk_raw in Consensus.trainers_for_epoch(Entry.epoch(entry)) do
        attestation = Fabric.my_attestation_by_entryhash(entry.hash)
        Map.put(msg, :attestation_packed, Attestation.pack(attestation))
      else msg end

      msg = pack_message(msg)
      {:ok, ip} = :inet.parse_address(~c'#{peer}')
      port = Application.fetch_env!(:ama, :udp_port)
      :gen_udp.send(socket, ip, port, msg)
    end)
  end

  def send_attestation_to_peer(socket, peer, attestation_packed) do
    msg = %{op: "attestation", attestation_packed: attestation_packed}
    msg = pack_message(msg)
    {:ok, ip} = :inet.parse_address(~c'#{peer}')
    port = Application.fetch_env!(:ama, :udp_port)
    :gen_udp.send(socket, ip, port, msg)
  end

  def send_txpool_to_peer(socket, peer) do
    txu = TXPool.random()
    if txu do
      msg = %{op: "txpool", tx_packed: TX.wrap(txu)}
      msg = pack_message(msg)
      {:ok, ip} = :inet.parse_address(~c'#{peer}')
      port = Application.fetch_env!(:ama, :udp_port)
      :gen_udp.send(socket, ip, port, msg)
    end
  end

  def send_peer_to_peer(socket, peer) do
    rng_peer = random_peer()
    if rng_peer do
      msg = %{op: "peer", ip: rng_peer.ip}
      msg = pack_message(msg)
      {:ok, ip} = :inet.parse_address(~c'#{peer}')
      port = Application.fetch_env!(:ama, :udp_port)
      :gen_udp.send(socket, ip, port, msg)
    end
  end

  def tick() do
    peers_clear_stale()
  end

  def handle_info(msg, state) do
    case msg do
      :ping ->
        :erlang.send_after(1000, self(), :ping)
        broadcast_ping()

      :tick ->
        :erlang.send_after(1000, self(), :tick)
        tick()

      {:send_to_others, opmap} ->
        msg = pack_message(opmap)
        peer_ips = peers()
        |> Enum.map(& &1.ip)

        #IO.puts IO.ANSI.green() <> inspect({:relay_to, peer_ips, byte_size(msg), opmap.op}) <> IO.ANSI.reset()

        Enum.each(peer_ips, fn(ip)->
          {:ok, ip} = :inet.parse_address(~c'#{ip}')
          port = Application.fetch_env!(:ama, :udp_port)
          :gen_udp.send(state.socket, ip, port, msg)
        end)

      {:udp, _socket, ip, _inportno, data} ->
        case unpack_message(data) do
          %{error: :ok, msg: msg} ->
            ip = Tuple.to_list(ip) |> Enum.join(".")
            #IO.puts IO.ANSI.red() <> inspect({:relay_from, ip, msg.op}) <> IO.ANSI.reset()
            proc(state, ip, msg, msg.signer)
          _ -> nil
        end
        :ok = :inet.setopts(state.socket, [{:active, :once}])
    end
    {:noreply, state}
  end

  def proc(state, ip, term, signer) do
    cond do
      term.op == "txpool" ->
        if TX.validate(term.tx_packed).error == :ok do
          #IO.inspect {:new_tx, term.tx_packed}
          TXPool.insert(term.tx_packed)
        end
      term.op == "entry" ->
        res = Entry.unpack_and_validate(term.entry_packed)
        if res.error == :ok do
          send(FabricGen, {:insert_entry, res.entry})
        end
        atp = term[:attestation_packed]
        if atp do
          res = Attestation.unpack_and_validate(atp)
          if res.error == :ok do
            send(FabricGen, {:add_attestation, res.attestation})
          end
        end
      term.op == "attestation" ->
        res = Attestation.unpack_and_validate(term.attestation_packed)
        if res.error == :ok and Attestation.validate_vs_chain(res.attestation) do
          send(FabricGen, {:add_attestation, res.attestation})
        end
      term.op == "need_attestation" ->
        attestation_packed = Fabric.get_or_resign_my_attestation(term.entry_hash)
        if attestation_packed do
          send_attestation_to_peer(state.socket, ip, attestation_packed)
        end

      term.op == "sol" ->
        <<epoch::32-little, sol_pk_raw::48-binary, pop_raw::96-binary, computor_raw::48-binary, _::binary>> = term.sol
        trainer_pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
        cond do
          epoch != Consensus.chain_epoch() -> nil
          trainer_pk_raw == sol_pk_raw and trainer_pk_raw == computor_raw ->
            IO.inspect {:broadcasted_sol_to_self, term.sol}
            nil
          !BIC.Epoch.validate_sol(term.sol) ->
            IO.inspect {:peer_sent_invalid_sol, :TODO_block_malicious_peer}
            nil
          !BlsEx.verify_signature?(sol_pk_raw, sol_pk_raw, pop_raw) ->
            IO.inspect {:peer_sent_invalid_sol_pop, :TODO_block_malicious_peer}
            nil
          trainer_pk_raw == sol_pk_raw ->
            pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
            sk_raw = Application.fetch_env!(:ama, :trainer_sk_raw)
            if Consensus.chain_balance(pk_raw) >= BIC.Coin.to_flat(1) do
              tx_packed = TX.build_transaction(sk_raw, Consensus.chain_height(), "Epoch", "submit_sol", [Base58.encode(term.sol)])
              TXPool.insert(tx_packed)
              tx_packed = TX.build_transaction(sk_raw, Consensus.chain_height(), "Coin", "transfer", [Base58.encode(computor_raw), BIC.Coin.to_cents(10)])
              TXPool.insert(tx_packed)
            end
          true -> nil
        end
      term.op == "peer" ->
        peer = :ets.lookup_element(NODEPeers, term.ip, 2, %{})
        peer = Map.merge(peer, %{ip: term.ip})
        :ets.insert(NODEPeers, {term.ip, peer})
      term.op == "ping" ->
        peer = :ets.lookup_element(NODEPeers, ip, 2, %{})
        peer = Map.merge(peer, %{ip: ip, pk: signer, last_ping: :os.system_time(1000), 
            height: term.entry_height, hash: term.entry_hash})
        :ets.insert(NODEPeers, {ip, peer})

        highest_height = :persistent_term.get(:highest_height, 0)
        :persistent_term.put(:highest_height, max(highest_height, term.entry_height))

        %{header_unpacked: %{height: height}} = Consensus.chain_tip_entry()
        Enum.each(0..30, fn(idx)->
          if height > (term.entry_height+idx) do send_entry_to_peer(state.socket, ip, term.entry_height+idx+1) end
        end)
        send_txpool_to_peer(state.socket, ip)
        send_peer_to_peer(state.socket, ip)
    end
  end

  #TODO: enable later if needed
  @doc """
  def generate_challenge(pk, sk, workdir) do
    IO.inspect {:looking_for, <<0,0,0,1>>}
    {challenge, signature} = generate_challenge_1(pk, sk)
    Application.put_env(:ama, :challenge, challenge)
    Application.put_env(:ama, :challenge_signature, signature)

    File.write!(Path.join(workdir, "trainer_challenge"), <<challenge::binary, signature::binary>>)
    IO.puts "challenge solved! restart amadeusd"
    :erlang.halt()
  end
  defp generate_challenge_1(pk, sk, best_challenge \\ <<>>, best \\ <<0xff>>, target \\ <<0,0,0,1>>) do
    challenge = :crypto.strong_rand_bytes(12)
    signature = :public_key.sign(challenge, :ignored, {:ed_pri, :ed25519, pk, sk}, [])
    cond do
      signature <= target -> {challenge, signature}
      signature < best ->
        IO.inspect {:found_better, challenge, :need, <<0,0,0,1>>}
        IO.inspect signature, limit: :infinity
        generate_challenge_1(pk, sk, challenge, signature, target)
      true -> generate_challenge_1(pk, sk, best_challenge, best, target)
    end
  end
  """

  def pack_message(msg) do
    pk_raw = Application.fetch_env!(:ama, :trainer_pk_raw)
    sk_raw = Application.fetch_env!(:ama, :trainer_sk_raw)
    
    #TODO: enable later if needed
    #challenge = Application.fetch_env!(:ama, :challenge)
    #challenge_signature = Application.fetch_env!(:ama, :challenge_signature)
    #msg = Map.merge(msg, %{signer: pk_b58, challenge: Base58.encode(challenge), challenge_signature: Base58.encode(challenge_signature)})
    msg_packed = msg
    |> Map.put(:signer, pk_raw)
    |> :erlang.term_to_binary([:deterministic])
    hash = Blake3.hash(msg_packed)
    signature = BlsEx.sign!(sk_raw, hash)
    msg_envelope = %{msg_packed: msg_packed, hash: hash, signature: signature}
    msg_envelope_packed = msg_envelope
    |> :erlang.term_to_binary([:deterministic])
    |> :zlib.gzip()

    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = encrypt(iv, msg_envelope_packed)
    <<iv::12-binary, tag::16-binary, ciphertext::binary>>
  end

  def unpack_message(data) do
    try do
      <<iv::12-binary, tag::16-binary, ciphertext::binary>> = data
      plaintext = decrypt(iv, tag, ciphertext)
      msg_envelope = plaintext
      |> :zlib.gunzip()
      |> :erlang.binary_to_term([:safe])

      msg = :erlang.binary_to_term(msg_envelope.msg_packed, [:safe])

      if msg_envelope.hash != Blake3.hash(msg_envelope.msg_packed), do: throw(%{error: :invalid_hash})
      if !BlsEx.verify_signature?(msg.signer, msg_envelope.hash, msg_envelope.signature), do: throw(%{error: :invalid_signature})
      if msg.signer == Application.fetch_env!(:ama, :trainer_pk_raw), do: throw(%{error: :msg_to_self})

      %{error: :ok, msg: msg}
    catch 
      throw,r -> %{error: r}
      e,r -> %{error: e, reason: r}
    end
  end

  #useless key to prevent udp noise
  def aes256key do
    <<108, 81, 112, 94, 44, 225, 200, 37, 227, 180, 114, 230, 230, 219, 177, 28, 
    80, 19, 72, 13, 196, 129, 81, 216, 161, 36, 177, 212, 199, 6, 169, 26>>
  end

  def encrypt(iv, text) do
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, aes256key(), iv, text, <<>>, 16, true)
    {ciphertext, tag}
  end

  def decrypt(iv, tag, ciphertext) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, aes256key(), iv, ciphertext, <<>>, tag, false)
  end
end

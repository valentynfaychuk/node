defmodule NodeGen do
  def start_link(ip, port) do
    :ets.new(NODEPeers, [:ordered_set, :named_table, :public,
      {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])
    :ets.new(NODEBlocks, [:ordered_set, :named_table, :public,
      {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])

    pid = :erlang.spawn_link(__MODULE__, :init, [ip, port])
    :erlang.register(__MODULE__, pid)
    {:ok, pid}
  end

  def init(ip_tuple, port) do
    lsocket = listen(port, [{:ifaddr, ip_tuple}])
    ip = Tuple.to_list(ip_tuple) |> Enum.join(".")
    state = %{ip: ip, ip_tuple: ip_tuple, port: port, socket: lsocket}
    :erlang.send_after(1000, self(), :tick)
    :erlang.send_after(1000, self(), :ping)
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

  def random_peer() do
    :ets.tab2list(NODEPeers)
    |> Enum.map(& elem(&1,1))
    |> case do
      [] -> nil
      list -> Enum.random(list)
    end
  end

  def peers(state) do
    seeds = Application.fetch_env!(:ama, :seednodes)
    nodes = Application.fetch_env!(:ama, :othernodes)
    peers = :ets.tab2list(NODEPeers)
    peers = Enum.reduce(peers, [], fn({ip, _}, acc)->
      acc++[ip]
    end)
    Enum.uniq(seeds ++ nodes ++ peers) -- [state.ip]
  end

  def peers_clear_stale() do
    ts_m = :os.system_time(1000)
    peers = :ets.tab2list(NODEPeers)
    |> Enum.each(fn {key, v}->
      lp = v[:last_ping]
      #3 minutes
      if !!lp and ts_m > lp+(1_000*60*3) do
        :ets.delete(NODEPeers, key)
      end
    end)
  end

  def consume_blocks() do
    height = Blockchain.height()
    blocks = :ets.match_object(NODEBlocks, {{height+1,:_},:_})
    cond do
      blocks == [] -> nil
      blocks ->
        {_, block_packed} = Enum.random(blocks)
        Blockchain.insert_block(block_packed)
        new_height = Blockchain.height()
        if new_height > height do
          consume_blocks()
        end
    end
  end

  def send_ping() do
    %{block: lb, hash: lb_hash} = Blockchain.block_last()
    msg = %{op: "ping", block_height: lb.height, block_hash: lb_hash}
    send(NodeGen, {:send_to_others, msg})
  end

  def send_txpool(tx_packed) do
    msg = %{op: "txpool", tx_packed: tx_packed}
    send(NodeGen, {:send_to_others, msg})
  end

  def send_block(block_packed) do
    msg = %{op: "block", block_packed: block_packed}
    send(NodeGen, {:send_to_others, msg})
  end

  def send_sol(sol) do
    msg = %{op: "sol", sol: Base58.encode(sol)}
    send(NodeGen, {:send_to_others, msg})
  end

  def send_block_to_peer(socket, peer, height) do
    bu = Blockchain.block_by_height(height)
    if bu do
      msg = %{op: "block", block_packed: Block.wrap(bu)}
      msg = pack_message(msg)
      {:ok, ip} = :inet.parse_address(~c'#{peer}')
      port = Application.fetch_env!(:ama, :udp_port)
      :gen_udp.send(socket, ip, port, msg)
    end
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

  def tick(state) do
    peers_clear_stale()
    consume_blocks()
    if Blockchain.is_in_slot() do
      #IO.puts "🔧 producing block.."
      block_packed = Blockchain.produce_block()
      bu = Block.unwrap(block_packed)
      #IO.puts "📦 produced_block #{bu.block.height} #{bu.hash}"
      send_block(block_packed)
    end
    state
  end

  def read_loop(state) do
  	receive do
      :ping ->
        :erlang.send_after(1000, self(), :ping)
        send_ping()
        __MODULE__.read_loop(state)

      :tick ->
        :erlang.send_after(1000, self(), :tick)
        state = tick(state)
        __MODULE__.read_loop(state)

      {:send_to_others, opmap} ->
        msg = pack_message(opmap)
        peer_ips = peers(state)

        #IO.puts IO.ANSI.green() <> inspect({:relay_to, peer_ips, opmap.op}) <> IO.ANSI.reset()

        Enum.each(peer_ips, fn(ip)->
          {:ok, ip} = :inet.parse_address(~c'#{ip}')
          port = Application.fetch_env!(:ama, :udp_port)
          :gen_udp.send(state.socket, ip, port, msg)
        end)
        __MODULE__.read_loop(state)

      {:udp, _socket, ip, _inportno, data} ->
        case unpack_message(data) do
          %{error: :ok, msg: term, signer: signer} ->
            ip = Tuple.to_list(ip) |> Enum.join(".")
            #IO.puts IO.ANSI.red() <> inspect({:relay_from, ip, term.op}) <> IO.ANSI.reset()
            proc(state, ip, term, signer)
          _ -> nil
        end
        :ok = :inet.setopts(state.socket, [{:active, :once}])
        __MODULE__.read_loop(state)
    end
  end

  def proc(state, ip, term, signer) do
    cond do
      term.op == "txpool" -> 
        if TX.validate(term.tx_packed) == %{error: :ok} do
          #IO.inspect {:new_tx, term.tx_packed}
          TXPool.insert(term.tx_packed)
        end
      #term.op == "block" ->
      #  if Block.validate(term.block_packed) == %{error: :ok} do
      #    #IO.inspect {:new_block, term.block_packed}
      #    Blockchain.insert_block(term.block_packed)
      #  end
      term.op == "block" ->
        if Block.validate_shell(term.block_packed) == %{error: :ok} do
          #IO.inspect {:new_block, term.block_packed}
          bu = Block.unwrap(term.block_packed)
          if Blockchain.height() == (bu.block.height-1) and Blockchain.hash() == bu.block.prev_hash do
            #IO.inspect {:new_block, term.block_packed}
            Blockchain.insert_block(term.block_packed)
          else
            :ets.insert(NODEBlocks, {{bu.block.height, bu.hash}, term.block_packed})
          end
        end
      term.op == "sol" ->
        <<trainer_pubkey_raw::32-binary, solver_raw::32-binary, epoch::32-little, _::binary>> = Base58.decode(term.sol)
        trainer_pk = Application.fetch_env!(:ama, :trainer_pk)
        cond do
          epoch != Blockchain.epoch() -> nil
          trainer_pk == trainer_pubkey_raw and trainer_pk == solver_raw ->
            IO.inspect {:broadcasted_sol_to_self, term.sol}
            nil
          !BIC.Trainer.validate_sol(Base58.decode(term.sol)) ->
            IO.inspect {:peer_sent_invalid_sol, :blocking_malicious_peer}
            nil
          trainer_pk == trainer_pubkey_raw ->
            sk_raw = Application.fetch_env!(:ama, :trainer_sk)
            signed_tx = TX.build_transaction(sk_raw, Blockchain.height(), "Trainer", "submit_sol", [term.sol])
            TXPool.insert(signed_tx)
            signed_tx = TX.build_transaction(sk_raw, Blockchain.height(), "Coin", "transfer", [Base58.encode(solver_raw), BIC.Coin.to_cents(10)])
            TXPool.insert(signed_tx)
          true -> nil
        end
      term.op == "peer" ->
        peer = :ets.lookup_element(NODEPeers, term.ip, 2, %{})
        peer = Map.merge(peer, %{ip: term.ip})
        :ets.insert(NODEPeers, {term.ip, peer})
      term.op == "ping" ->
        peer = :ets.lookup_element(NODEPeers, ip, 2, %{})
        peer = Map.merge(peer, %{ip: ip, pk: signer, last_ping: :os.system_time(1000)})
        :ets.insert(NODEPeers, {ip, peer})

        highest_height = :persistent_term.get(:highest_height, 0)
        :persistent_term.put(:highest_height, max(highest_height, term.block_height))

        %{block: latest_block} = Blockchain.block_last()
        latest_height = latest_block.height
        Enum.each(0..30, fn(idx)->
          if latest_height > (term.block_height+idx) do send_block_to_peer(state.socket, ip, term.block_height+idx+1) end
        end)
        send_txpool_to_peer(state.socket, ip)
        send_peer_to_peer(state.socket, ip)
    end
  end

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

  def pack_message(msg) do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    pk_b58 = Application.fetch_env!(:ama, :trainer_pk_b58)
    sk = Application.fetch_env!(:ama, :trainer_sk)
    challenge = Application.fetch_env!(:ama, :challenge)
    challenge_signature = Application.fetch_env!(:ama, :challenge_signature)
    msg = Map.merge(msg, %{signer: pk_b58, 
      challenge: Base58.encode(challenge), challenge_signature: Base58.encode(challenge_signature)})
    packed = JCS.serialize(msg)

    hash = Blake3.hash(packed)
    signature = :public_key.sign(hash, :ignored, {:ed_pri, :ed25519, pk, sk}, [])
    pck = <<Base58.encode(hash)::binary,".",Base58.encode(signature)::binary,".",packed::binary>>
    |> :zlib.gzip()

    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = encrypt(iv, pck)
    <<iv::12-binary, tag::16-binary, ciphertext::binary>>
  end

  def unpack_message(data) do
    try do
      <<iv::12-binary, tag::16-binary, ciphertext::binary>> = data
      plaintext = decrypt(iv, tag, ciphertext)
      plaintext = :zlib.gunzip(plaintext)
      [hash, plaintext] = :binary.split(plaintext, ".")
      [signature, packed] = :binary.split(plaintext, ".")
      term = JSX.decode!(packed, labels: :attempt_atom)
      hash = Base58.decode(hash)
      signature = Base58.decode(signature)
      signer = Base58.decode(term.signer)
      challenge = Base58.decode(term.challenge)
      challenge_signature = Base58.decode(term.challenge_signature)
      if hash != Blake3.hash(packed), do: throw(%{error: :invalid_hash})
      if !:public_key.verify(hash, :ignored, signature, {:ed_pub, :ed25519, signer}), do: throw(%{error: :invalid_signature})
      if !String.starts_with?(challenge_signature, <<0,0,0,4>>) and !String.starts_with?(challenge_signature, <<0,0,0,1>>), do: throw(%{error: :invalid_challenge})
      if !:public_key.verify(challenge, :ignored, challenge_signature, {:ed_pub, :ed25519, signer}), do: throw(%{error: :invalid_signature_challenge})
      %{error: :ok, msg: term, signer: term.signer}
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

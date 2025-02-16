defmodule NodeState do
  import NodeProto

  def init() do
    %{
    }
  end

  def handle(:ping, istate, term) do
    temporal = Entry.unpack(term.temporal)
    rooted = Entry.unpack(term.rooted)
    %{error: :ok} = Entry.validate_signature(temporal.header, temporal.signature, temporal.header_unpacked.signer)
    %{error: :ok} = Entry.validate_signature(rooted.header, rooted.signature, rooted.header_unpacked.signer)

    :erlang.spawn(fn()->
      #txs_packed = TXPool.random()
      #txs_packed && send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(NodeProto.txpool(txs_packed))})

      rng_peers = NodePeers.random(6) |> Enum.map(& &1.ip)
      if rng_peers != [], do: send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(NodeProto.peers(rng_peers))})
    end)

    term = %{temporal: temporal, rooted: rooted, ts_m: term.ts_m}
    send(NodeGen, {:handle_sync, :ping_ns, istate, term})
  end
  def handle(:ping_ns, istate, term) do
    peer_ip = istate.peer.ip
    peer = :ets.lookup_element(NODEPeers, peer_ip, 2, %{})
    peer = Map.merge(peer, %{
        ip: peer_ip,
        pk: istate.peer.signer, version: istate.peer.version,
        last_ping: :os.system_time(1000),
        temporal: term.temporal, rooted: term.rooted,
    })
    :ets.insert(NODEPeers, {peer_ip, peer})

    :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [peer_ip], pack_message(NodeProto.pong(term.ts_m))}) end)

    istate.ns
  end


  def handle(:pong, istate, term) do
    term = %{seen_time: :os.system_time(1000), ts_m: term.ts_m}
    send(NodeGen, {:handle_sync, :pong_ns, istate, term})
  end
  def handle(:pong_ns, istate, term) do
    peer_ip = istate.peer.ip
    peer = :ets.lookup_element(NODEPeers, peer_ip, 2, %{})
    latency = term.seen_time - term.ts_m
    peer = Map.merge(peer, %{latency: latency, last_pong: term.seen_time})
    :ets.insert(NODEPeers, {peer_ip, peer})

    istate.ns
  end

  def handle(:txpool, istate, term) do
    good = Enum.filter(term.txs_packed, & TX.validate(&1).error == :ok)
    TXPool.insert(good)
  end

  def handle(:peers, istate, term) do
    send(NodeGen, {:handle_sync, :peers_ns, istate, term})
  end
  def handle(:peers_ns, istate, term) do
    Enum.each(term.ips, fn(peer_ip)->
      peer = :ets.lookup_element(NODEPeers, peer_ip, 2, %{})
      peer = Map.merge(peer, %{ip: peer_ip})
      :ets.insert(NODEPeers, {peer_ip, peer})
    end)
    istate.ns
  end

  #def handle(:sol, istate, term) do nil end
  def handle(:sol, istate, term) do
    sol = BIC.Sol.unpack(term.sol)
    trainer_pk = Application.fetch_env!(:ama, :trainer_pk)
    cond do
      sol.epoch != Consensus.chain_epoch() ->
        IO.inspect {:broadcasted_sol_invalid_epoch, sol.epoch, Consensus.chain_epoch()}
        nil
      !BIC.Sol.verify(term.sol) ->
        IO.inspect {:peer_sent_invalid_sol, :TODO_block_malicious_peer}
        nil
      !BlsEx.verify?(sol.pk, sol.pop, sol.pk, BLS12AggSig.dst_pop()) ->
        IO.inspect {:peer_sent_invalid_sol_pop, :TODO_block_malicious_peer}
        nil
      trainer_pk == sol.pk ->
        sk = Application.fetch_env!(:ama, :trainer_sk)
        if Consensus.chain_balance(trainer_pk) >= BIC.Coin.to_flat(1) do
          IO.inspect {:peer_sent_sol, Base58.encode(istate.peer.signer)}
          tx_packed1 = TX.build(sk, "Epoch", "submit_sol", [term.sol])
          tx_packed2 = TX.build(sk, "Coin", "transfer", [sol.computor, BIC.Coin.to_cents(30)])
          TXPool.insert([tx_packed1, tx_packed2])
        end
      true -> nil
    end
  end

  def handle(:entry, istate, term) do
    seen_time = :os.system_time(1000)

    %{error: :ok, entry: entry} = Entry.unpack_and_validate(term.entry_packed)
    cond do
        !!term[:consensus_packed] ->
            c = Consensus.unpack(term.consensus_packed)
            send(FabricCoordinatorGen, {:insert_entry_validate_consensus, entry, c, seen_time})

        !!term[:attestation_packed] ->
            %{error: :ok, attestation: a} = Attestation.unpack_and_validate(term.attestation_packed)
            send(FabricCoordinatorGen, {:insert_entry_attestation, entry, a, seen_time})

        true ->
            send(FabricCoordinatorGen, {:insert_entry, entry, seen_time})
    end
  end

  def handle(:attestation_bulk, istate, term) do
    #IO.inspect {:got, :attestation_bulk,  istate.peer.ip}
    Enum.each(term.attestations_packed, fn(attestation_packed)->
        res = Attestation.unpack_and_validate(attestation_packed)
        if res.error == :ok and Attestation.validate_vs_chain(res.attestation) do
          send(FabricCoordinatorGen, {:add_attestation, res.attestation})
        end
    end)
  end

  def handle(:consensus_bulk, istate, term) do
    Enum.each(term.consensuses_packed, fn(consensus_packed)->
        c = Consensus.unpack(consensus_packed)
        send(FabricCoordinatorGen, {:validate_consensus, c})
    end)
  end

  def handle(:catchup_tri, istate, term) do
    true = length(term.heights) <= 30

    Enum.each(term.heights, fn(height)->
        case Fabric.get_entries_by_height_w_attestation_or_consensus(height) do
            [] -> nil
            map_entries ->
              Enum.each(map_entries, fn(map)->
                msg = cond do
                  map[:consensus] ->
                    NodeProto.entry(%{entry_packed: Entry.pack(map.entry), consensus_packed: Consensus.pack(map.consensus)})
                  map[:attest] ->
                    NodeProto.entry(%{entry_packed: Entry.pack(map.entry), attestation_packed: Attestation.pack(map.attest)})
                  true ->
                    NodeProto.entry(%{entry_packed: Entry.pack(map.entry)})
                end
                :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(msg)}) end)
              end)
        end
    end)
  end

  def handle(:catchup_bi, istate, term) do
    true = length(term.heights) <= 30

    {attestations_packed, consensuses_packed} = Enum.reduce(term.heights, {[], []}, fn(height, {a, c})->
        {attests, consens} = Fabric.get_attestations_or_consensuses_by_height(height)
        attests = Enum.map(attests, & Attestation.pack(&1))
        consens = Enum.map(consens, & Consensus.pack(&1))
        {a ++ attests, c ++ consens}
    end)

    if length(attestations_packed) > 0 do
        Enum.chunk_every(attestations_packed, 3)
        |> Enum.each(fn(bulk)->
            msg = NodeProto.attestation_bulk(bulk)
            :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(msg)}) end)
        end)
    end

    if length(consensuses_packed) > 0 do
        Enum.chunk_every(consensuses_packed, 3)
        |> Enum.each(fn(bulk)->
            msg = NodeProto.consensus_bulk(bulk)
            :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(msg)}) end)
        end)
    end
  end

  def handle(:catchup_attestation, istate, term) do
    #IO.inspect {:got, :catchup_attestation,  istate.peer.ip}

    true = length(term.hashes) <= 30

    attestations_packed = Enum.map(term.hashes, fn(hash)->
      Fabric.my_attestation_by_entryhash(hash)
    end)
    |> Enum.filter(& &1)
    |> Enum.map(& Attestation.pack(&1))

    if length(attestations_packed) > 0 do
        Enum.chunk_every(attestations_packed, 3)
        |> Enum.each(fn(bulk)->
            msg = NodeProto.attestation_bulk(bulk)
            :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(msg)}) end)
        end)
    end
  end

  def handle(:special_business, istate, term) do
    op = term.business.op
    cond do
      #istate.peer.pk != <<>> -> nil
      op == "slash_trainer" ->
        signature = SpecialMeetingGen.check_maybe_attest("slash_trainer", term.business.epoch, term.business.malicious_pk)
        if signature do
          pk = Application.fetch_env!(:ama, :trainer_pk)
          business = %{op: "slash_trainer_reply", epoch: term.business.epoch, malicious_pk: term.business.malicious_pk, 
            pk: pk, signature: signature}
          msg = NodeProto.special_business_reply(business)
          :erlang.spawn(fn()-> send(NodeGen, {:send_to_some, [istate.peer.ip], pack_message(msg)}) end)
        end
    end
  end

  def handle(:special_business_reply, istate, term) do
    IO.inspect {:special_business_reply, term.business}
    op = term.business.op
    cond do
      #istate.peer.pk != <<>> -> nil
      op == "slash_trainer_reply" ->
        b = term.business
        msg = <<"slash_trainer", b.epoch::32-little, b.malicious_pk::binary>>
        sigValid = BlsEx.verify?(b.pk, b.signature, msg, BLS12AggSig.dst_motion())
        if sigValid do
          send(SpecialMeetingGen, {:add_slash_trainer_reply, term.business})
        end
    end
  end
end
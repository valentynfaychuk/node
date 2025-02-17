defmodule SpecialMeetingGen do
  use GenServer

  def isNextSlotStalled() do
    :persistent_term.get({SpecialMeeting, :nextSlotStalled}, nil)
  end

  def offlineTrainers() do
    :persistent_term.get({SpecialMeeting, :offlineTrainers}, [])
  end

  def try_slash_trainer(mpk) do
    send(SpecialMeetingGen, {:try_slash_trainer, mpk})
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(6000, self(), :tick)
    :erlang.send_after(6000, self(), :tick_offline)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    true && tick(state)
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def handle_info(:tick_offline, state) do
    true && tick_offline(state)
    :erlang.send_after(60_000, self(), :tick_offline)
    {:noreply, state}
  end

  def my_tickslice() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()

    my_height = entry.header_unpacked.height
    slot = entry.header_unpacked.slot
    next_slot = slot + 1
    next_height = my_height + 1

    trainers = Consensus.trainers_for_height(next_height)
    #TODO: make this 3 or 6 later
    sync_round_offset = rem(div(:os.system_time(1), 60), length(trainers))
    sync_round_index = Enum.find_index(trainers, fn t -> t == pk end)

    sync_round_offset == sync_round_index
  end

  #TODO: move to fabric
  def last_x_seentime(no \\ 10) do
  end

  def tick(state) do
    isSynced = FabricSyncGen.isQuorumSyncedOffBy1()

    entry = Consensus.chain_tip_entry()
    next_slot = entry.header_unpacked.slot + 1
    next_height = entry.header_unpacked.height + 1
    next_slot_trainer = Consensus.trainer_for_slot(next_height, next_slot)

    ts_m = :os.system_time(1000)
    seen_time = Fabric.entry_seentime(entry.hash)
    delta = ts_m - seen_time

    nextSlotStalled = :persistent_term.get({SpecialMeeting, :nextSlotStalled}, nil)

    #TODO: check for Slowloris
    #avg_seentimes_last_10_slots(malicious_pk) > 1second -> true

    #TODO: make this tighter later
    #no entry in 30seconds

    cond do
        !isSynced -> nil
        delta < 30_000 and nextSlotStalled -> :persistent_term.delete({SpecialMeeting, :nextSlotStalled})
        delta >= 30_000 and !nextSlotStalled -> :persistent_term.put({SpecialMeeting, :nextSlotStalled}, next_slot_trainer)
        true -> nil
    end
    #check for the last entry time, if we have not
    #had any new entries in the last X seconds
    #AND we are synced with the network
    #AND it is our timeround to call the meeting
    #WE call the special meeting to remove the malicious peer

    #IF a peer has not reached thier target slottime (we always
    #get late entries from the peer) RECORD
    #IF a peer is not producing an entry at all RECORD

    #WE can call the meeting and see if the peer consensus
    #agrees. This GenServer will be the local source of truth
  end

  def tick_offline(state) do
    isSynced = FabricSyncGen.isQuorumSyncedOffBy1()

    trainers = Consensus.trainers_for_height(Consensus.chain_height()+1)
    onlineTrainers = trainers
    |> Enum.filter(fn(pk)->
        p = NodePeers.by_pk(pk)
        cond do
          Application.fetch_env!(:ama, :trainer_pk) == pk -> true
          !!p and NodePeers.is_online(p) -> true
          true -> false
        end
    end)
    offlineTrainers = trainers -- onlineTrainers

    offlineLocal = Process.get(:offlineTrainersSeries, []) |> Enum.take(10)
    offlineLocal = [offlineTrainers] ++ offlineLocal
    Process.put(:offlineTrainersSeries, offlineLocal)

    offlinePTerm = :persistent_term.get({SpecialMeeting, :offlineTrainers}, [])

    xIntervalOffline = offlineLocal
    |> Enum.map(&MapSet.new/1)
    |> Enum.reduce(&MapSet.intersection/2)
    |> MapSet.to_list()
    |> Enum.sort()

    cond do
        !isSynced -> nil
        length(offlineLocal) < 10 -> nil
        offlinePTerm != xIntervalOffline -> :persistent_term.put({SpecialMeeting, :offlineTrainers}, xIntervalOffline)
        true -> nil
    end
  end

  def check_maybe_attest("slash_trainer", epoch, malicious_pk) do
    slotStallTrainer = isNextSlotStalled()
    cond do
        byte_size(malicious_pk) != 48 -> nil
        Consensus.chain_epoch() != epoch -> nil

        #TODO: check for Slowloris
        #avg_seentimes_last_10_slots(malicious_pk) > 1second -> true

        malicious_pk == slotStallTrainer or malicious_pk in SpecialMeetingGen.offlineTrainers()->
            msg = <<"slash_trainer", epoch::32-little, malicious_pk::binary>>
            sk = Application.fetch_env!(:ama, :trainer_sk)
            BlsEx.sign!(sk, msg, BLS12AggSig.dst_motion())

        true -> nil
    end
  end

  def check(business) do
    if check_business(business) do

    end
  end

  def check_business(business = %{op: "slash_trainer", malicious_pk: malicious_pk}) do
    slotStallTrainer = isNextSlotStalled()

    cond do
        byte_size(malicious_pk) != 48 -> false

        #TODO: check for Slowloris
        #avg_seentimes_last_10_slots(malicious_pk) > 1second -> true

        malicious_pk == slotStallTrainer -> true

        true -> false
    end
  end

  def handle_info({:try_slash_trainer, mpk}, state) do
    height = Consensus.chain_height()
    epoch = Consensus.chain_epoch()

    trainers = Consensus.trainers_for_height(height)
    my_pk = Application.fetch_env!(:ama, :trainer_pk)
    state = cond do
      my_pk in trainers and (!state[:slash_trainer] or state.slash_trainer.malicious_pk != mpk) ->
        signature = check_maybe_attest("slash_trainer", epoch, mpk)
        true = byte_size(signature) == 96
        ma = BLS12AggSig.new(trainers, my_pk, signature)
        Map.put(state, :slash_trainer, %{malicious_pk: mpk, epoch: epoch, mask: ma.mask, aggsig: ma.aggsig})
      !state[:slash_trainer] or state.slash_trainer.malicious_pk != mpk ->
        Map.put(state, :slash_trainer, %{malicious_pk: mpk, epoch: epoch})
      true -> state
    end

    state = if !state[:slash_trainer] or state.slash_trainer.malicious_pk != mpk do
      Map.put(state, :slash_trainer, %{malicious_pk: mpk, epoch: epoch})
    else
      state
    end

    business = %{op: "slash_trainer", height: height, epoch: epoch, malicious_pk: mpk}
    NodeGen.broadcast(:special_business, :trainers, [business])

    {:noreply, state}
  end

  def handle_info({:add_slash_trainer_reply, business}, state = %{slash_trainer: _}) do
    st = state.slash_trainer
    trainers = Consensus.trainers_for_height(st.height)
    state = cond do
      !st[:aggsig] ->
        ma = BLS12AggSig.new(trainers, business.pk, business.signature)
        state = put_in(state, [:slash_trainer, :mask], ma.mask)
        put_in(state, [:slash_trainer, :aggsig], ma.aggsig)

      true ->
        ma = BLS12AggSig.add(%{mask: st.mask, aggsig: st.aggsig}, trainers, business.pk, business.signature)
        state = put_in(state, [:slash_trainer, :mask], ma.mask)
        put_in(state, [:slash_trainer, :aggsig], ma.aggsig)
    end

    score = BLS12AggSig.score(trainers, state.slash_trainer.mask)
    IO.inspect score
    if score >= 0.75 do
      pad_to_byte = fn(bitstring)->
        bits = bit_size(bitstring)
        padding = rem(8 - rem(bits, 8), 8)
        <<bitstring::bitstring, 0::size(padding)>>
      end

      my_pk = Application.fetch_env!(:ama, :trainer_pk)
      my_sk = Application.fetch_env!(:ama, :trainer_sk)
      packed_tx = TX.build(my_sk, "Epoch", "slash_trainer", 
        [st.epoch, st.malicious_pk, st.aggsig, bit_size(st.mask), pad_to_byte.(st.mask)], Consensus.chain_nonce(my_pk)+1)

      true = FabricSyncGen.isQuorumSynced()
      cur_entry = Consensus.chain_tip_entry()
      cur_height = cur_entry.header_unpacked.height
      cur_slot = cur_entry.header_unpacked.slot

      true = my_pk == Consensus.trainer_for_slot(Consensus.chain_height(), cur_slot)

      [rewound_entry] = Fabric.entries_by_height(cur_height-1)
      next_entry = Entry.build_next(rewound_entry, cur_slot)
      txs = [packed_tx]
      next_entry = Map.put(next_entry, :txs, txs)
      next_entry = Entry.sign(next_entry)

      IO.inspect next_entry, limit: 11111111111
      send(FabricCoordinatorGen, {:insert_entry, next_entry, :os.system_time(1000)})
    end

    {:noreply, state}
  end
end
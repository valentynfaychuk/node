defmodule SpecialMeetingGen do
  use GenServer

  def isNextSlotStalled() do
    :persistent_term.get({SpecialMeeting, :nextSlotStalled}, nil)
  end

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :erlang.send_after(6000, self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    true && tick(state)
    :erlang.send_after(1000, self(), :tick)
    {:noreply, state}
  end

  def my_tickslice() do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    entry = Consensus.chain_tip_entry()

    my_height = entry.header_unpacked.height
    slot = entry.header_unpacked.slot
    next_slot = slot + 1
    next_epoch = div(my_height+1, 100_000)

    trainers = Consensus.trainers_for_epoch(next_epoch)
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
    next_epoch = div(entry.header_unpacked.height + 1, 100_000)
    next_slot_trainer = Consensus.trainer_for_slot(next_epoch, next_slot)

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

  def check_maybe_attest("slash_trainer", epoch, malicious_pk) do
    slotStallTrainer = isNextSlotStalled()
    cond do
        byte_size(malicious_pk) != 48 -> nil
        Consensus.chain_epoch() != epoch -> nil

        #TODO: check for Slowloris
        #avg_seentimes_last_10_slots(malicious_pk) > 1second -> true

        slotStallTrainer == malicious_pk ->
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
end
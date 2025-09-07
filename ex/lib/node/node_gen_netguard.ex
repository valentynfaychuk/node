defmodule NodeGenNetguard do
  @max_frames_per_6_sec 20_000
  @max_msg_per_6_sec %{
    new_phone_who_dis: 10,
    new_phone_who_dis_reply: 10,
    peers: 10,
    peers_reply: 10,
    ping: 10,
    ping_reply: 10,
    special_business: 10,
    special_business_reply: 10,
    catchup: 10,
    catchup_reply: 10,
    solicit_entry: 10,
    event_entry: 30,
    event_tx: 6000,
    event_attestion: 6000,
    solicity_entry: 2,
    sell_sol: 10_000,
  }
  @msg_ops Enum.into(@max_msg_per_6_sec, %{}, & {elem(&1,0), true})

  def frame_ok(peer_ip) do
    phash = :erlang.phash2(peer_ip, 8)
    counter = :ets.update_counter(:'NODENetGuardTotalFrames#{phash}', peer_ip, 1, {peer_ip, 0})
    counter < @max_frames_per_6_sec
  end

  def op_ok(peer_ip, op) do
    if @msg_ops[op] do
      phash = :erlang.phash2(peer_ip, 8)
      counter = :ets.update_counter(:'NODENetGuardPer6Seconds#{phash}', {peer_ip, op}, 1, {{peer_ip, op}, 0})
      counter < @max_msg_per_6_sec[op]
    end
  end

  def decrement_buckets(idx) do
    step = trunc(@max_frames_per_6_sec / 2)
    :ets.foldl(fn({peer_ip, _}, nil)->
      :ets.update_counter(:'NODENetGuardTotalFrames#{idx}', peer_ip, {2, -step, 0, 0})
    end, nil, :'NODENetGuardTotalFrames#{idx}')

    :ets.foldl(fn({{peer_ip, op}, _}, nil)->
      step = trunc(@max_msg_per_6_sec[op] / 2)
      :ets.update_counter(:'NODENetGuardPer6Seconds#{idx}', {peer_ip, op}, {2, -step, 0, 0})
    end, nil, :'NODENetGuardPer6Seconds#{idx}')
  end
end

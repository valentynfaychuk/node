defmodule NodeProto do

  def new_phone_who_dis() do
    %{op: :new_phone_who_dis}
  end
  def new_phone_who_dis_reply() do
    anr = NodeANR.build()
    %{op: :new_phone_who_dis_reply, anr: anr}
  end

  def get_peer_anrs() do
    existing_peers = NodeANR.b3_f4()
    %{op: :get_peer_anrs, hasPeersb3f4: existing_peers}
  end
  def get_peer_anrs_reply(missing_anrs) do
    %{op: :get_peer_anrs_reply, anrs: missing_anrs}
  end

  def ping(ts_m) do
    %{op: :ping, ts_m: ts_m}
  end
  def ping_reply(ts_m) do
    %{op: :ping_reply, ts_m: ts_m}
  end

  def event_tip() do
    tip = DB.Chain.tip_entry()
    temporal = tip |> Map.take([:header, :signature, :mask, :mask_size, :mask_set_size])
    rooted = DB.Chain.rooted_tip_entry() |> Map.take([:header, :signature, :mask, :mask_size, :mask_set_size])
    %{op: :event_tip, temporal: temporal, rooted: rooted, ts_m: :os.system_time(1000)}
  end

  def event_tx(tx_packed) when is_binary(tx_packed) do event_tx([tx_packed]) end
  def event_tx(txs_packed) when is_list(txs_packed) do
    %{op: :event_tx, txs_packed: txs_packed}
  end

  def event_tx2(tx_packed) when is_binary(tx_packed) do event_tx2([tx_packed]) end
  def event_tx2(txs_packed) when is_list(txs_packed) do
    txus = Enum.map(txs_packed, & TX.unpack(&1))
    %{op: :event_tx, txs: txus, txs_packed: []}
  end

  def event_entry(entry_packed) do
    %{op: :event_entry, entry_packed: entry_packed}
  end

  def event_attestation(attestations) do
    %{op: :event_attestation, attestations: List.wrap(attestations)}
  end

  def catchup(height_flags) do
    %{op: :catchup, height_flags: height_flags}
  end
  def catchup_reply(tries) do
    %{op: :catchup_reply, tries: tries}
  end

  def special_business(business) do
    %{op: :special_business, business: business}
  end

  def special_business_reply(business) do
    %{op: :special_business_reply, business: business}
  end

  def decompress_and_unpack(compressed_data) do
    vec = compressed_data
    |> :zstd.decompress()
    |> IO.iodata_to_binary()
    |> RDB.vecpak_decode()
    Map.put(vec, :op, String.to_existing_atom(vec.op))
  end

  def compress(msg) do
    msg
    |> RDB.vecpak_encode()
    |> :zstd.compress()
    |> IO.iodata_to_binary()
  end

  def encrypt_message(msg_compressed, shared_key) do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    version_3byte = Application.fetch_env!(:ama, :version_3b)

    ts_n = :os.system_time(:nanosecond)
    iv = :crypto.strong_rand_bytes(12)
    key = :crypto.hash(:sha256, [shared_key, :binary.encode_unsigned(ts_n), iv])
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, msg_compressed, <<>>, 16, true)

    payload = <<iv::binary, tag::binary, ciphertext::binary>>
    if byte_size(payload) < 1360 do
      [<<"AMA", version_3byte::binary, 0, pk::binary, 0::16, 1::16, ts_n::64, byte_size(payload)::32, payload::binary>>]
    else
      shards = div(byte_size(payload)+1023, 1024)
      r = ReedSolomonEx.create_resource(shards, shards, 1024)
      ReedSolomonEx.encode_shards(r, payload)
      |> Enum.take(shards+1+div(shards,4))
      |> Enum.map(fn {idx, shard}->
        <<"AMA", version_3byte::binary, 0, pk::binary, idx::16, (shards*2)::16, ts_n::64, byte_size(payload)::32, shard::binary>>
      end)
    end
  end

  def unpack_message(<<"AMA", va, vb, vc, 0::8, pk::48-binary, s_idx::16, s_total::16, ts_n::64, original_size::32, payload::binary>>) do
    try do
      if pk == Application.fetch_env!(:ama, :trainer_pk), do: throw(%{error: :msg_to_self})

      version = "#{va}.#{vb}.#{vc}"
      if version < "1.2.5", do: throw(%{error: :old_version})

      if s_total >= 10_000, do: throw(%{error: :too_large_shard})
      if original_size >= 1024_0_000, do: throw(%{error: :too_large_size})

      %{pk: pk, ts_nano: ts_n, shard_index: s_idx, shard_total: s_total, version: version,
        original_size: original_size, payload: :binary.copy(payload)}
    catch
      throw,r -> %{error: r}
      e,r -> %{error: e, reason: r}
    end
  end

  def unpack_message(data) do
    %{error: :unknown_data}
  end
end

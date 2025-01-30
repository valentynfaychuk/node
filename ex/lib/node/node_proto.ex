defmodule NodeProto do
  def ping() do
    tip = Consensus.chain_tip_entry()
    temporal = tip |> Map.take([:header, :signature])
    rooted = Fabric.rooted_tip_entry() |> Map.take([:header, :signature])
    %{op: :ping, temporal: temporal, rooted: rooted, ts_m: :os.system_time(1000)}
  end

  def pong(ts_m) do
    %{op: :pong, ts_m: ts_m}
  end

  def txpool(txs_packed) do
    %{op: :txpool, txs_packed: txs_packed}
  end

  def peers(ips) do
    %{op: :peers, ips: ips}
  end

  def sol(sol) do
    %{op: :sol, sol: sol}
  end

  def entry(map) do
    msg = %{op: :entry, entry_packed: map.entry_packed}
    msg = if !map[:attestation_packed] do msg else Map.put(msg, :attestation_packed, map.attestation_packed) end
    msg = if !map[:consensus_packed] do msg else Map.put(msg, :consensus_packed, map.consensus_packed) end
    msg
  end

  def attestation_bulk(attestations_packed) do
    %{op: :attestation_bulk, attestations_packed: attestations_packed}
  end

  def consensus_bulk(consensuses_packed) do
    %{op: :consensus_bulk, consensuses_packed: consensuses_packed}
  end

  def catchup_tri(heights) do
    %{op: :catchup_tri, heights: heights}
  end

  def catchup_bi(heights) do
    %{op: :catchup_bi, heights: heights}
  end





  def pack_message(msg) do
    pk = Application.fetch_env!(:ama, :trainer_pk)
    sk = Application.fetch_env!(:ama, :trainer_sk)
    
    #TODO: enable later if needed
    #challenge = Application.fetch_env!(:ama, :challenge)
    #challenge_signature = Application.fetch_env!(:ama, :challenge_signature)
    #msg = Map.merge(msg, %{signer: pk, challenge: challenge, challenge_signature: challenge_signature})
    msg_packed = msg
    |> Map.put(:signer, pk)
    |> Map.put(:version, Application.fetch_env!(:ama, :version))
    |> :erlang.term_to_binary([:deterministic])
    hash = Blake3.hash(msg_packed)
    signature = BlsEx.sign!(sk, hash, BLS12AggSig.dst_node())
    msg_envelope = %{msg_packed: msg_packed, signature: signature}
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
      hash = Blake3.hash(msg_envelope.msg_packed)
      if !BlsEx.verify?(msg.signer, msg_envelope.signature, hash, BLS12AggSig.dst_node()), do: throw(%{error: :invalid_signature})
      if msg.signer == Application.fetch_env!(:ama, :trainer_pk), do: throw(%{error: :msg_to_self})

      %{error: :ok, msg: msg}
    catch 
      throw,r -> %{error: r}
      e,r -> %{error: e, reason: r}
    end
  end

  #useless key to prevent udp noise
  def aes256key do
    <<0, 1, 33, 94, 44, 225, 200, 37, 227, 180, 114, 230, 230, 219, 177, 28, 
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
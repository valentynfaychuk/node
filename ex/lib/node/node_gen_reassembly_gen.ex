defmodule NodeGenReassemblyGen do
  use GenServer

  def start_link(name \\ __MODULE__) do
    GenServer.start_link(__MODULE__, [name], name: name)
  end

  def init([name]) do
    state = %{name: name, reorg: %{}}
    :erlang.send_after(8000, self(), :tick)
    {:ok, state}
  end

  def clear_stale(state) do
    threshold = :os.system_time(:nanosecond) - 8_000_000_000
    reorg = state.reorg
    |> Map.filter(fn {{_pk, ts_nano, _shard_total}, _value} ->
        ts_nano > threshold
    end)
    put_in(state, [:reorg], reorg)
  end

  def handle_info(:tick, state) do
    state = clear_stale(state)
    :erlang.send_after(8000, self(), :tick)
    {:noreply, state}
  end

  def handle_info({:add_shard, key={pk, ts_nano, shard_total}, {ip, version_3byte, shared_secret, signature, shard_index, original_size}, shard}, state) do
    old_shards = get_in(state, [:reorg, key])
    cond do
        !old_shards -> {:noreply, put_in(state, [:reorg, key], %{shard_index=> shard})}
        old_shards == :spent -> {:noreply, state}

        map_size(old_shards) < (div(shard_total,2)-1) -> {:noreply, put_in(state, [:reorg, key, shard_index], shard)}

        true ->
            state = put_in(state, [:reorg, key], :spent)

            shards = :maps.to_list(old_shards) ++ [{shard_index, shard}]

            try do
                r = BlsEx.Native.create_resource(div(shard_total,2), div(shard_total,2), 1024)
                payload = BlsEx.Native.decode_shards(r, shards, shard_total, original_size)
                proc_msg(pk, shared_secret, signature, ts_nano, ip, version_3byte, payload)
            catch
                e,r -> IO.inspect {:msg_reassemble_failed, e, r, __STACKTRACE__}
            end
            {:noreply, state}
    end
  end

  def proc_msg(pk, shared_secret, signature, ts_nano, ip, version_3byte, payload) do
    try do
      if signature do
        valid = BlsEx.verify?(pk, signature, Blake3.hash(pk<>payload), BLS12AggSig.dst_node())
        if valid do

          msg = payload
          |> NodeProto.deflate_decompress()
          |> :erlang.binary_to_term([:safe])

          #IO.inspect {:reassembled, msg}

          :erlang.spawn(fn()->
            peer = %{ip: ip, version: version_3byte, signer: pk}
            NodeState.handle(msg.op, %{peer: peer}, msg)
          end)
        end
      else
        <<iv::12-binary, tag::16-binary, ciphertext::binary>> = payload
        key = :crypto.hash(:sha256, [shared_secret, :binary.encode_unsigned(ts_nano), iv])
        plaintext = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false)

        msg = plaintext
        |> NodeProto.deflate_decompress()
        |> :erlang.binary_to_term([:safe])

        #IO.inspect {:reassembled, msg}

        :erlang.spawn(fn()->
          peer = %{ip: ip, version: version_3byte, signer: pk}
          NodeState.handle(msg.op, %{peer: peer}, msg)
        end)
      end
    catch
        e,r -> IO.inspect {:msg_decode_failed, e, r, __STACKTRACE__}
    end
  end
end

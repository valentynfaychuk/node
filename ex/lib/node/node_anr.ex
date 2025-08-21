defmodule NodeANR do
  @doc """
  AMA Node Record
  """

  @keys [:ip4, :pk, :port, :signature, :ts, :version]
  @keys_for_signature [:ip4, :pk, :port, :ts, :version]

  def seed() do
    Application.fetch_env!(:ama, :seedanrs)
    |> Enum.each(fn(anr)->
      insert(anr)
    end)
    insert(build())
    set_handshaked(Application.fetch_env!(:ama, :trainer_pk))
  end

  def build() do
    sk = Application.fetch_env!(:ama, :trainer_sk)
    pk = Application.fetch_env!(:ama, :trainer_pk)
    ver = Application.fetch_env!(:ama, :version)
    build(sk, pk, STUN.get_current_ip4(), ver)
  end

  #TODO: Later change this to erlang term
  def build(sk, pk, ip4, ver) do
    anr = %{
      ip4: ip4,
      pk: pk,
      port: 36969,
      ts: :os.system_time(1),
      version: ver
    }
    anr_to_sign = anr |> :erlang.term_to_binary([:deterministic])
    sig = BlsEx.sign!(sk, anr_to_sign, BLS12AggSig.dst_anr())
    anr = Map.put(anr, :signature, sig)
  end

  def pack(anr) do
    Map.take(anr, @keys)
  end

  def unpack(anr) do
    if anr.port == 36969 do
      Map.take(anr, @keys)
    end
  end

  def verify_signature(anr) do
    signed = Map.take(anr, @keys_for_signature)
    |> :erlang.term_to_binary([:deterministic])
    BlsEx.verify?(anr.pk, anr.signature, signed, BLS12AggSig.dst_anr())
  end

  def verify_and_unpack(anr) do
    try do
      # Not wound into future
      ts = :os.system_time(1000)
      delta = ts - anr.ts
      min10 = 60*10
      goodDelta = delta > -min10

      # Not too big
      bin = :erlang.term_to_binary(anr, [:deterministic])
      anr = Map.take(anr, @keys)
      if byte_size(bin) <= 280 and goodDelta and verify_signature(anr) do
        anr
      end
    catch
      _,_ -> nil
    end
  end

  def insert(anr) do
    anr = Map.put(anr, :pop, API.Epoch.get_pop(anr.pk))
    old_anr = MnesiaKV.get(NODEANR, anr.pk)
    if !old_anr do
      anr = Map.put(anr, :handshaked, false)
      anr = Map.put(anr, :error, nil)
      anr = Map.put(anr, :error_tries, 0)
      anr = Map.put(anr, :next_check, :os.system_time(1)+3)
      MnesiaKV.merge(NODEANR, anr.pk, anr)
    else
      insert_1(old_anr, anr)
    end
  end

  def insert_1(old_anr, anr) do
    same_ip4_port = old_anr.ip4 == anr.ip4 and old_anr.port == anr.port
    cond do
      anr.ts <= old_anr.ts -> nil
      same_ip4_port -> MnesiaKV.merge(NODEANR, anr.pk, anr)
      true ->
        anr = Map.put(anr, :handshaked, false)
        anr = Map.put(anr, :error, nil)
        anr = Map.put(anr, :error_tries, 0)
        anr = Map.put(anr, :next_check, :os.system_time(1)+3)
        MnesiaKV.merge(NODEANR, anr.pk, anr)
    end
  end

  def set_handshaked(pk) do
    MnesiaKV.merge(NODEANR, pk, %{handshaked: true})
  end

  def not_handshaked_pk_ip4() do
    :ets.select(:"Elixir.NODEANR_index", [{{{:'$1', false, :'$2'}, :_}, [], [{{:'$1', :'$2'}}]}])
  end

  def handshaked_pk_ip4() do
    :ets.select(:"Elixir.NODEANR_index", [{{{:'$1', true, :'$2'}, :_}, [], [{{:'$1', :'$2'}}]}])
  end

  def handshaked() do
    :ets.select(:"Elixir.NODEANR_index", [{{{:'$1', true, :_}, :_}, [], [:'$1']}])
  end

  def handshaked(pk) when is_binary(pk) do
    case :ets.select(:"Elixir.NODEANR_index", [{{{pk, true, :_}, :_}, [], [true]}], 1) do
      :"$end_of_table" -> false
      {[true], _} -> true
    end
  end

  def by_pks_ip(pks) when is_list(pks) do
    match_spec = Enum.map(pks, fn(pk)-> {{{pk, true, :'$1'}, :_}, [], [:'$1']} end)
    :ets.select(:"Elixir.NODEANR_index", match_spec)
  end

  def handshaked_and_valid_ip4(pk, ip4) do
    case :ets.select(:"Elixir.NODEANR_index", [{{{pk, true, ip4}, :_}, [], [true]}], 1) do
      :"$end_of_table" -> false
      {[true], _} -> true
    end
  end

  def all() do
    MnesiaKV.get(NODEANR)
  end

  def get_random_verified(cnt \\ 3) do
    handshaked()
    |> Enum.shuffle()
    |> Enum.take(cnt)
    |> Enum.map(& pack(MnesiaKV.get(NODEANR, &1)))
  end

  def get_random_unverified(cnt \\ 1) do
    not_handshaked_pk_ip4()
    |> Enum.shuffle()
    |> Enum.take(cnt)
    |> Enum.uniq_by(& elem(&1,1))
  end
end

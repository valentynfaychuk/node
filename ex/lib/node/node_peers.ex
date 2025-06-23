defmodule NodePeers do
  def seed(my_ip) do
    seeds = Application.fetch_env!(:ama, :seednodes)
    nodes = Application.fetch_env!(:ama, :othernodes)
    filtered = Enum.uniq(seeds ++ nodes) -- [my_ip]
    Enum.each(filtered, fn(ip)->
      :ets.insert(NODEPeers, {ip, %{ip: ip, static: true}})
    end)
  end

  def random(no) do
    online()
    |> case do
      [] -> []
      peers ->
        Enum.shuffle(peers)
        |> Enum.take(no)
    end
  end

  def clear_stale() do
    ts_m = :os.system_time(1000)
    :ets.foldl(fn({key, v}, acc)->
      lp = v[:last_msg]
      #60 minutes
      if !v[:static] and !!lp and ts_m > lp+(1_000*60*60) do
        acc ++ [key]
      else
        acc
      end
    end, [], NODEPeers)
    |> Enum.each(& :ets.delete(NODEPeers, &1))
  end

  def all() do
    peers = :ets.tab2list(NODEPeers)
    |> Enum.map(& elem(&1,1))
  end

  def all_trainers(height \\ nil) do
    height = if !height do Consensus.chain_height() else height end
    pks = Consensus.trainers_for_height(height+1)

    match_spec = Enum.map(pks, fn(pk)-> {{:"$1", %{pk: pk}}, [], [:"$1"]} end)
    :ets.select(NODEPeers, match_spec)
    |> Enum.map(&(:ets.lookup_element(NODEPeers, &1, 2, nil)))
  end

  def summary() do
    :ets.tab2list(NODEPeers)
    |> Enum.map(fn {_, p}->
      [
        p.ip,
        p[:latency],
        get_in(p, [:temporal, :header_unpacked, :height]),
        get_in(p, [:rooted, :header_unpacked, :height])
      ]
    end)
    |> Enum.sort_by(fn([ip|_])->
      {:ok, ip} = :inet.parse_address(~c'#{ip}')
      ip
    end)
  end

  def summary_online() do
    online()
    |> Enum.map(fn(p)->
      [
        p.ip,
        p[:latency],
        get_in(p, [:temporal, :header_unpacked, :height]),
        get_in(p, [:rooted, :header_unpacked, :height])
      ]
    end)
  end

  def online() do
    peers = :ets.tab2list(NODEPeers)
    |> Enum.reduce([], fn ({_key, v}, acc)->
      if is_online(v) do
        acc ++ [v]
      else
        acc
      end
    end)
  end

  def is_online(peer) do
    ts_m = :os.system_time(1000)
    lp = peer[:last_ping]
    cond do
      !peer[:pk] -> false
      Application.fetch_env!(:ama, :trainer_pk) == peer.pk -> true
      !!lp and ts_m - lp <= 3_000 -> true
      true -> false
    end
  end

  def get_shared_secret(pk) do
    shared_secret = :ets.select(NODEPeers, [{{:_, %{pk: pk, shared_secret: :"$1"}}, [], [:"$1"]}])
    |> List.first()
    if shared_secret do shared_secret else
      BlsEx.get_shared_secret!(pk, Application.fetch_env!(:ama, :trainer_sk))
    end
  end

  def by_ip(ip) do
    :ets.select(NODEPeers, [{{ip, :"$1"}, [], [:"$1"]}])
    |> List.first()
  end

  def by_pk(pk) do
    ip = :ets.select(NODEPeers, [{{:"$1", %{pk: pk}}, [], [:"$1"]}])
    |> List.first()
    :ets.lookup_element(NODEPeers, ip, 2, nil)
  end

  def by_pks(pks) do
    match_spec = Enum.map(pks, fn(pk)-> {{:"$1", %{pk: pk}}, [], [:"$1"]} end)
    :ets.select(NODEPeers, match_spec)
    |> Enum.map(&(:ets.lookup_element(NODEPeers, &1, 2, nil)))
  end

  def for_height(height) do
    trainers = Consensus.trainers_for_height(height)
    peers = :ets.tab2list(NODEPeers)
    |> Enum.map(& elem(&1,1))
    |> Enum.filter(& &1[:pk] in trainers)
  end

  def by_who({:some, peer_ips}) do
    peer_ips
  end
  def by_who(:trainers) do
    NodePeers.for_height(Consensus.chain_height()+1)
    |> Enum.map(& &1.ip)
    |> case do
      [] -> []
      peers -> Enum.shuffle(peers)
    end
  end
  def by_who({:not_trainers, cnt}) do
    trainers = NodePeers.for_height(Consensus.chain_height()+1)
    |> Enum.map(& &1.ip)
    peers = :ets.tab2list(NODEPeers)
    |> Enum.map(& elem(&1,1).ip)
    not_trainers = peers -- trainers
    case not_trainers do
      [] -> []
      peers -> Enum.shuffle(peers) |> Enum.take(cnt)
    end
  end
  def by_who(no_random) do
    random(no_random)
    |> Enum.map(& &1.ip)
  end

  def highest_height(filter) do
    filtered = summary_online()
    |> Enum.filter(fn([_ip, lat, temp, rooted | _ ]) ->
      min_temporal = filter[:min_temporal] || 0
      min_rooted = filter[:min_rooted] || 0
      temp >= min_temporal and rooted >= min_rooted
    end)
    |> Enum.sort_by(fn([ip, _lat, temp, rooted | _ ]) ->
      sort = filter[:sort] || :temporal
      if sort == :temporal do temp else rooted end
    end, :desc)
    highest_height_1(filtered, filter)
  end

  defp highest_height_1(filtered, f=%{latency: l, latency1: l1, latency2: l2}) do
    new = Enum.filter(filtered, fn([_ip, lat, _temp, _rooted | _ ]) ->
      lat <= l2
    end)
    take = f[:take] || 3
    cond do
      length(new) >= take -> highest_height_1(new, Map.delete(f, :latency2))
      true -> filtered
    end
  end
  defp highest_height_1(filtered, f=%{latency: l, latency1: l1}) do
    new = Enum.filter(filtered, fn([_ip, lat, _temp, _rooted | _ ]) ->
      lat <= l1
    end)
    take = f[:take] || 3
    cond do
      length(new) >= take -> highest_height_1(new, Map.delete(f, :latency1))
      true -> filtered
    end
  end
  defp highest_height_1(filtered, f=%{latency: l}) do
    new = Enum.filter(filtered, fn([_ip, lat, _temp, _rooted | _ ]) ->
      lat <= l
    end)
    take = f[:take] || 3
    cond do
      length(new) >= take -> Enum.take(new, take)
      true -> filtered
    end
  end
  defp highest_height_1(filtered, _) do
    filtered
  end
end

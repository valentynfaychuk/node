import Config

config :ama, :node_started_time, :os.system_time(1000)

version = Application.fetch_env!(:ama, :version)
[v1,v2,v3] = version
|> String.trim("v")
|> String.split(".")
config :ama, :version_3b, <<:erlang.binary_to_integer(v1),:erlang.binary_to_integer(v2),:erlang.binary_to_integer(v3)>>

work_folder = (System.get_env("WORKFOLDER") || Path.expand("~/.cache/amadeusd/"))
config :ama, :work_folder, work_folder

:ok = File.mkdir_p!(work_folder)

#load env
#Envvar.load(Path.join([work_folder, ".env"]))

config :ama, :snapshot_height, (System.get_env("SNAPSHOT_HEIGHT") || "28812306") |> :erlang.binary_to_integer()

#Bind Interaces
config :ama, :offline, (!!System.get_env("OFFLINE") || nil)

config :ama, :http_ipv4, ((System.get_env("HTTP_IPV4") || "0.0.0.0") |> :unicode.characters_to_list() |> :inet.parse_ipv4_address() |> (case do {:ok, addr}-> addr end))
config :ama, :http_port, (System.get_env("HTTP_PORT") || "80") |> :erlang.binary_to_integer()

udp_ipv4_iface =  ((System.get_env("UDP_IPV4") || "0.0.0.0") |> :unicode.characters_to_list() |> :inet.parse_ipv4_address() |> (case do {:ok, addr}-> addr end))
config :ama, :udp_ipv4_tuple, udp_ipv4_iface
config :ama, :udp_port, 36969

#Nodes
config :ama, :seednodes, ["104.218.45.23", "72.9.144.110"]
config :ama, :othernodes, (try do (System.get_env("OTHERNODES") |> String.split(",")) || [] catch _,_ -> [] end)
config :ama, :trustfactor, (try do System.get_env("TRUSTFACTOR") |> :erlang.binary_to_float() catch _,_ -> 0.8 end)

if !Util.verify_time_sync() do
    IO.puts "🔴 🕒 time not synced OR systemd-ntp client not found; DYOR 🔴"
end

path = Path.join([work_folder, "sk"])
if !File.exists?(path) do
    IO.puts "No trainer sk (BLS12-381) in #{path} as base58"
    sk = :crypto.strong_rand_bytes(64)
    pk = BlsEx.get_public_key!(sk)
    IO.puts "generated random sk, your pk is #{Base58.encode(pk)}"
    :ok = File.write!(path, Base58.encode(sk))
end
sk = File.read!(path) |> String.trim() |> Base58.decode()
pk = BlsEx.get_public_key!(sk)
pop = BlsEx.sign!(sk, pk, BLS12AggSig.dst_pop())

config :ama, :trainer_pk_b58, pk |> Base58.encode()
config :ama, :trainer_pk, pk
config :ama, :trainer_sk, sk
config :ama, :trainer_pop, pop

config :ama, :archival_node, System.get_env("ARCHIVALNODE") in ["true", "y", "yes"]
config :ama, :autoupdate, System.get_env("AUTOUPDATE") in ["true", "y", "yes"]
config :ama, :computor_type, (case System.get_env("COMPUTOR") do nil -> nil; "trainer" -> :trainer; _ -> :default end)

pub_ipv4 = (System.get_env("PUBLIC_UDP_IPV4") || STUN.get_current_ip4(udp_ipv4_iface))
config :ama, :public_udp_ipv4, pub_ipv4
config :ama, :max_peers, (System.get_env("MAX_PEERS") || "300") |> :erlang.binary_to_integer()
config :ama, :buy_peer_sol, System.get_env("BUY_PEER_SOL") in ["true", "y", "yes"]

anr_name = System.get_env("ANR_NAME")
anr_desc = System.get_env("ANR_DESC")

config :ama, :anr, NodeANR.build(sk, pk, pop, pub_ipv4, version, anr_name, anr_desc)
config :ama, :anr_next_refresh, :os.system_time(1000) + 60_000*60
config :ama, :anr_name, anr_name
config :ama, :anr_desc, anr_desc

Path.join(work_folder, "ex/")
|> Path.join("**/*.ex")
|> Path.wildcard()
|> Enum.each(fn file ->
  Code.require_file(file)
end)

#TODO: enable this later
#path = Path.join([work_folder, "trainer_challenge"])
#if !File.exists?(path) do
#    IO.puts "trainer did not solve basic challenge in #{path}"
#    IO.puts "solving challenge to join network.. this can take a while"
#    Enum.each(1..:erlang.system_info(:schedulers_online), fn(_)->
#        :erlang.spawn(fn()-> NodeGen.generate_challenge(pk, sk, work_folder) end)
#    end)
#    receive do _ -> :infinite_loop end
#else
#    <<challenge::12-binary, signature::96-binary>> = File.read!(path)
#    Application.put_env(:ama, :challenge, challenge)
#    Application.put_env(:ama, :challenge_signature, signature)
#end

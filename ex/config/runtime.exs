import Config

work_folder = (System.get_env("WORKFOLDER") || Path.expand("~/.cache/amadeusd/"))
config :ama, :work_folder, work_folder

:ok = File.mkdir_p!(work_folder)

#load env
#Envvar.load(Path.join([work_folder, ".env"]))

#Bind Interaces
config :ama, :http_ip4, ((System.get_env("HTTP_IP4") || "0.0.0.0") |> :unicode.characters_to_list() |> :inet.parse_ipv4_address() |> (case do {:ok, addr}-> addr end))
config :ama, :http_port, (System.get_env("HTTP_PORT") || "1090") |> :erlang.binary_to_integer()

config :ama, :udp_ipv4_tuple, ((System.get_env("UDP_IPV4") || "0.0.0.0") |> :unicode.characters_to_list() |> :inet.parse_ipv4_address() |> (case do {:ok, addr}-> addr end))
config :ama, :udp_port, 36969

#Nodes
config :ama, :seednodes, ["104.218.45.23"]
config :ama, :othernodes, (try do (System.get_env("OTHERNODES") |> String.split(",")) || [] catch _,_ -> [] end)


path = Path.join([work_folder, "trainer_sk"])
if !File.exists?(path) do
    IO.puts "put your trainer sk (ed25519) into #{path}"
    :erlang.halt()
end
trainer_sk = File.read!(path) |> String.trim() |> Base58.decode()
{pk, _sk} = :crypto.generate_key(:eddsa, :ed25519, trainer_sk)

config :ama, :trainer_pk_b58, pk |> Base58.encode()
config :ama, :trainer_pk, pk
config :ama, :trainer_sk, trainer_sk

path = Path.join([work_folder, "trainer_challenge"])
if !File.exists?(path) do
    IO.puts "trainer did not solve basic challenge in #{path}"
    IO.puts "solving challenge to join network.. this can take a while"
    Enum.each(1..:erlang.system_info(:schedulers_online), fn(_)->
        :erlang.spawn(fn()-> NodeGen.generate_challenge(pk, trainer_sk, work_folder) end)
    end)
    receive do _ -> :infinite_loop end
else
    <<challenge::12-binary, signature::64-binary>> = File.read!(path)
    Application.put_env(:ama, :challenge, challenge)
    Application.put_env(:ama, :challenge_signature, signature)    
end

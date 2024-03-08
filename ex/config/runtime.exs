import Config

work_folder = (System.get_env("WORKFOLDER") || Path.expand("~/.cache/amadeus/"))
config :ama, :work_folder, work_folder

:ok = File.mkdir_p!(work_folder)

#load env
#Envvar.load(Path.join([work_folder, ".env"]))

#Bind Interaces
config :ama, :http_ip4, ((System.get_env("HTTP_IP4") || "0.0.0.0") |> :unicode.characters_to_list() |> :inet.parse_ipv4_address() |> (case do {:ok, addr}-> addr end))
config :ama, :http_port, (System.get_env("HTTP_PORT") || "1090") |> :erlang.binary_to_integer()

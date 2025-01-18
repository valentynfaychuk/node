defmodule Ama do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    #IO.inspect Application.app_dir(:ama, "priv/index.html") 

    supervisor = Supervisor.start_link([
      {DynamicSupervisor, strategy: :one_for_one, name: Ama.Supervisor, max_seconds: 1, max_restarts: 999_999_999_999}
    ], strategy: :one_for_one)

    Fabric.init()
    Fabric.insert_genesis()

    IO.puts "Initing TXPool.."
    TXPool.init()

    :ets.new(NODEPeers, [:ordered_set, :named_table, :public,
      {:write_concurrency, true}, {:read_concurrency, true}, {:decentralized_counters, false}])

    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: PG, start: {:pg, :start_link, []}})
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: PGWSPanel, start: {:pg, :start_link, [PGWSPanel]}})
    
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: ComputorGen, start: {ComputorGen, :start_link, []}})
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: LoggerGen, start: {LoggerGen, :start_link, []}})
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: FabricGen, start: {FabricGen, :start_link, []}})
    
    ip4 = Application.fetch_env!(:ama, :udp_ipv4_tuple)
    port = Application.fetch_env!(:ama, :udp_port)
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: NodeGen, start: {NodeGen, :start_link, [ip4, port]}, restart: :permanent})

    #web panel
    #ip4 = Application.fetch_env!(:ama, :http_ip4)
    #port = Application.fetch_env!(:ama, :http_port)
    #{a,b,c,d} = ip4
    #ip4_string = "#{a}.#{b}.#{c}.#{d}"
    #IO.puts "started http-api on #{ip4_string}:#{port}"

    #{:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{
    #  id: Photon.GenTCPAcceptor, start: {Photon.GenTCPAcceptor, :start_link, [ip4, port, Ama.MultiServer]}
    #})

    supervisor
  end
end
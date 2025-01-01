defmodule Ama do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    #IO.inspect Application.app_dir(:ama, "priv/index.html") 

    supervisor = Supervisor.start_link([
      {DynamicSupervisor, strategy: :one_for_one, name: Ama.Supervisor, max_seconds: 1, max_restarts: 999_999_999_999}
    ], strategy: :one_for_one)

    path = Path.join([Application.fetch_env!(:ama, :work_folder), "mnesia_kv/"])
    #MnesiaKV.load(%{
    #    TX => %{index: [:uuid, :status, :nonce, :type, :prev_tx]},
    #  },
    #  %{path: path}
    #)

    <<six::6-binary, _::binary>> = Application.fetch_env!(:ama, :challenge_signature)
    IO.inspect {:challenge_solved, six}

    IO.puts "Loading chain.."
    BIC.Base.init()
    Blockchain.load_chain_on_init()
    
    IO.puts "Initing TXPool.."
    TXPool.init()

    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: PG, start: {:pg, :start_link, []}})
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: PGWSPanel, start: {:pg, :start_link, [PGWSPanel]}})
    
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: Computor, start: {Computor, :start_link, []}})
    
    ip4 = Application.fetch_env!(:ama, :udp_ipv4_tuple)
    port = Application.fetch_env!(:ama, :udp_port)
    {:ok, _} = DynamicSupervisor.start_child(Ama.Supervisor, %{id: NodeGen, start: {NodeGen, :start_link, [ip4, port]}})

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
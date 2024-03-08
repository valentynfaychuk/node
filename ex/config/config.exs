import Config

config :ama, :version, Mix.Project.config[:version]

config :logger, truncate: :infinity

config :ama, :init_atoms, [
    :uuid, :owner,
]

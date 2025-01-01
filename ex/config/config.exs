import Config

config :logger, truncate: :infinity

config :ama, :version, Mix.Project.config[:version]

config :ama, :block_size, 1432
config :ama, :tx_size, 1024


import Config

config :logger, truncate: :infinity

config :ama, :version, Mix.Project.config[:version]

config :ama, :entry_size, 524288
config :ama, :tx_size, 393216
config :ama, :attestation_size, 512
config :ama, :quorum, 3
#config :ama, :quorum, 1

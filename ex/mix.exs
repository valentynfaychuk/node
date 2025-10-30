defmodule Ama.MixProject do
  use Mix.Project

  @app :ama

  def project do
    [
      app: @app,
      version: "1.2.2",
      elixir: ">= 1.18.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      build_embedded: Mix.env == :prod,
      releases: [{@app, release()}],
      preferred_cli_env: [release: :prod]
    ]
  end

  def application do
    apps = [
      extra_applications: [:iex, :logger, :crypto, :ssl, :inets]
    ]
    if Mix.env() == :prod do
      [{:mod, {Ama.Bakeware, []}} | apps]
    else
      [{:mod, {Ama, []}} | apps]
    end
  end

  defp deps do
    [
      {:bakeware, git: "https://github.com/vans163/bakeware", branch: "main", runtime: false},

      {:photon, git: "https://github.com/vans163/photon.git"},
      {:mnesia_kv, git: "https://github.com/xenomorphtech/mnesia_kv.git"},

      {:rustler, ">= 0.36.1", optional: true},
      {:blake3_ex, git: "https://github.com/vans163/blake3", branch: "finalize_xof"},
      {:bls_ex, git: "https://github.com/amadeus-robot/bls_ex"},
      {:reedsolomon_ex, git: "https://github.com/amadeus-robot/reedsolomon_ex"},
      {:wasmer_ex, git: "https://github.com/amadeus-robot/wasmer_ex"},

      {:comsat, git: "https://github.com/vans163/ComSat.git"},
      {:ex_stun, git: "https://github.com/elixir-webrtc/ex_stun.git"},
    ]
  end

  defp release do
    [
      overwrite: true,
      steps: [:assemble, &Bakeware.assemble/1],
      strip_beams: Mix.env() == :prod,
      bakeware: [
        compression_level: 1,
        #compression_level: 19,
        start_command: "start_iex"
      ],
    ]
  end

  defp rustler_crates do
    [
      blake3: [
        path: "native/blake3",
        mode: (Mix.env() == :prod && :release) || :debug,
        features: [:neon],
        default_features: true
      ]
    ]
  end
end

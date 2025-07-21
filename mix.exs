defmodule VsmExternalInterfaces.MixProject do
  use Mix.Project

  def project do
    [
      app: :vsm_external_interfaces,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {VsmExternalInterfaces.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP REST adapter
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      
      # WebSocket adapter  
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      
      # gRPC adapter
      {:grpc, "~> 0.7"},
      {:protobuf, "~> 0.11"},
      
      # VSM core integration (mock for development)
      # {:vsm_core, path: "../vsm-core"},
      # {:vsm_connections, path: "../vsm-connections"},
      
      # Utilities
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: :bench}
    ]
  end
end

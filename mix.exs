defmodule VsmExternalInterfaces.MixProject do
  use Mix.Project

  def project do
    [
      app: :vsm_external_interfaces,
      version: "0.1.0",
      elixir: "~> 1.17",
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
    base_deps = [
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
      
      # Utilities
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: :bench}
    ]
    
    vsm_deps = if in_umbrella?() do
      # In umbrella mode, dependencies are managed by the umbrella project
      []
    else
      [
        {:vsm_core, path: "../vsm-core"},
        {:vsm_connections, path: "../vsm-connections"},
        {:vsm_telemetry, path: "../vsm-telemetry", optional: true},
        {:vsm_goldrush, path: "../vsm-goldrush", optional: true}
      ]
    end
    
    base_deps ++ vsm_deps
  end
  
  defp in_umbrella? do
    Mix.Project.umbrella?()
  end
end

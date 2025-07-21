defmodule VsmExternalInterfaces.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Configure ports from environment or defaults
    http_port = System.get_env("HTTP_PORT", "4000") |> String.to_integer()
    websocket_port = System.get_env("WS_PORT", "4001") |> String.to_integer()
    grpc_port = System.get_env("GRPC_PORT", "50051") |> String.to_integer()
    
    children = [
      # Start the Telemetry supervisor
      {Phoenix.PubSub, name: VsmExternalInterfaces.PubSub},
      
      # VSM Telemetry integration (if available)
      maybe_start_telemetry(),
      
      # VSM Goldrush integration for pattern matching (if available)
      maybe_start_goldrush(),
      
      # VSM Bridge - connects to VSM core
      {VsmExternalInterfaces.Integrations.VsmBridge, 
       vsm_host: System.get_env("VSM_HOST", "localhost"),
       vsm_port: System.get_env("VSM_PORT", "9000") |> String.to_integer()},
      
      # HTTP/REST adapter
      {Plug.Cowboy, 
       scheme: :http, 
       plug: VsmExternalInterfaces.Adapters.HTTP, 
       options: [port: http_port]},
      
      # WebSocket adapter endpoint
      {VsmExternalInterfaces.Adapters.WebSocket,
       http: [port: websocket_port],
       server: true,
       pubsub_server: VsmExternalInterfaces.PubSub},
      
      # gRPC adapter server (commented out due to configuration issues)
      # {VsmExternalInterfaces.Adapters.GRPC.Server, port: grpc_port}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VsmExternalInterfaces.Supervisor]
    
    Logger.info("""
    Starting VSM External Interfaces:
    - HTTP REST API on port #{http_port}
    - WebSocket on port #{websocket_port}  
    - gRPC on port #{grpc_port}
    """)
    
    Supervisor.start_link(children, opts)
  end
  
  defp maybe_start_telemetry do
    if Code.ensure_loaded?(VsmTelemetry) do
      {VsmTelemetry.Supervisor, [
        metrics: vsm_metrics(),
        reporters: [
          {VsmTelemetry.Reporters.Console, interval: 60_000}
        ]
      ]}
    else
      []
    end
  end
  
  defp vsm_metrics do
    [
      # HTTP adapter metrics
      VsmTelemetry.Metrics.counter("vsm_external_interfaces.http.message_sent.count"),
      VsmTelemetry.Metrics.summary("vsm_external_interfaces.http.request.duration"),
      
      # WebSocket adapter metrics
      VsmTelemetry.Metrics.counter("vsm_external_interfaces.websocket.message_sent.count"),
      VsmTelemetry.Metrics.gauge("vsm_external_interfaces.websocket.connections.active"),
      
      # gRPC adapter metrics
      VsmTelemetry.Metrics.counter("vsm_external_interfaces.grpc.message_sent.count"),
      VsmTelemetry.Metrics.summary("vsm_external_interfaces.grpc.stream.duration"),
      
      # VSM Bridge metrics
      VsmTelemetry.Metrics.counter("vsm_bridge.message_sent.count", tags: [:system_id, :channel]),
      VsmTelemetry.Metrics.counter("vsm_bridge.algedonic_triggered.count", tags: [:severity]),
      
      # System health metrics
      VsmTelemetry.Metrics.gauge("vsm_external_interfaces.adapters.health", tags: [:adapter])
    ]
  end
  
  defp maybe_start_goldrush do
    if Code.ensure_loaded?(VsmGoldrush) do
      VsmExternalInterfaces.GoldrushIntegration
    else
      []
    end
  end
end

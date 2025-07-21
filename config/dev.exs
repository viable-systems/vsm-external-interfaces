import Config

# Development configuration

config :vsm_external_interfaces,
  # Override default ports for development
  http_port: 4000,
  websocket_port: 4001,
  grpc_port: 50051,
  
  # VSM core connection (local development)
  vsm_host: "localhost",
  vsm_port: 9000

# WebSocket endpoint configuration for development
config :vsm_external_interfaces, VsmExternalInterfaces.Adapters.WebSocket,
  http: [port: 4001],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: []

# Logger configuration for development
config :logger, :console, format: "[$level] $message\n"

# Reduce noise in development logs
config :phoenix, :stacktrace_depth, 20

# Enable telemetry in development
config :telemetry, :disable_default_metrics, false
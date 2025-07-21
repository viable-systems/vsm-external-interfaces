import Config

# Test configuration

config :vsm_external_interfaces,
  # Use different ports for testing to avoid conflicts
  http_port: 4002,
  websocket_port: 4003,
  grpc_port: 50052,
  
  # Mock VSM core connection for testing
  vsm_host: "localhost",
  vsm_port: 9001

# WebSocket endpoint configuration for testing
config :vsm_external_interfaces, VsmExternalInterfaces.Adapters.WebSocket,
  http: [port: 4003],
  server: false

# Print only warnings and errors during test
config :logger, level: :warn

# Disable telemetry in tests
config :telemetry, :disable_default_metrics, true
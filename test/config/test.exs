import Config

# Test environment configuration for VSM Interfaces

# Configure connection pools for testing
config :vsm_connections, :pools,
  test_pool: %{
    size: 5,
    max_overflow: 2,
    strategy: :lifo
  },
  benchmark_pool: %{
    size: 20,
    max_overflow: 10,
    strategy: :fifo
  }

# Configure HTTP adapter
config :vsm_connections, :http,
  default_timeout: 5_000,
  max_connections: 100,
  conn_opts: [
    transport_opts: [
      inet6: true,
      certfile: "test/fixtures/certs/client.crt",
      keyfile: "test/fixtures/certs/client.key"
    ]
  ]

# Configure WebSocket adapter
config :vsm_connections, :websocket,
  heartbeat_interval: 30_000,
  max_frame_size: 16_000_000,  # 16MB
  compress: true

# Configure gRPC adapter
config :vsm_connections, :grpc,
  keepalive_time: 30_000,
  keepalive_timeout: 5_000,
  max_receive_message_length: 4_194_304,  # 4MB
  max_send_message_length: 4_194_304      # 4MB

# Configure circuit breakers for testing
config :vsm_connections, :circuit_breaker,
  default: %{
    error_threshold: 5,
    error_threshold_timeout: 60_000,
    timeout: 3_000,
    state_timeout: 60_000
  }

# Configure telemetry for testing
config :vsm_connections, :telemetry,
  enabled: true,
  metrics: [
    "vsm_connections.adapter.request.duration",
    "vsm_connections.adapter.websocket.*.duration",
    "vsm_connections.adapter.grpc.duration",
    "vsm_connections.pool.checkout.duration",
    "vsm_connections.circuit_breaker.state_change"
  ]

# Test server configurations
config :vsm_connections, :test_servers,
  http_echo: "http://localhost:8080",
  ws_echo: "ws://localhost:8081",
  grpc_echo: "localhost:50051",
  slow_server: "http://localhost:8082",
  unreliable_server: "http://localhost:8083"

# Performance test configurations
config :vsm_connections, :performance,
  warmup_iterations: 100,
  benchmark_iterations: 1000,
  concurrent_connections: 50,
  test_duration: 30_000,  # 30 seconds
  payload_sizes: [
    small: 1024,        # 1KB
    medium: 102_400,    # 100KB
    large: 1_048_576    # 1MB
  ]

# Property test configurations
config :vsm_connections, :property_tests,
  max_runs: 100,
  max_shrinks: 50,
  seed: 42  # For reproducible tests

# E2E test configurations
config :vsm_connections, :e2e,
  chat_server: %{
    http_port: 9080,
    ws_port: 9081,
    grpc_port: 50061,
    max_users: 100,
    message_retention: 1000
  },
  streaming_server: %{
    http_port: 9082,
    ws_port: 9083,
    grpc_port: 50062,
    max_streams: 10,
    chunk_size: 51_200  # 50KB
  },
  iot_server: %{
    http_port: 9084,
    ws_port: 9085,
    grpc_port: 50063,
    max_sensors: 1000,
    aggregation_interval: 1000
  }

# Mock server configurations
config :vsm_connections, :mocks,
  bypass_timeout: 100,
  websocket_server: VsmConnections.MockWebSocketServer,
  grpc_server: VsmConnections.MockGRPCServer

# Test timeouts
config :vsm_connections, :timeouts,
  unit_test: 5_000,
  integration_test: 30_000,
  performance_test: 300_000,
  e2e_test: 600_000

# Logger configuration for tests
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :test_case]

config :logger,
  level: :warning,  # Reduce noise during tests
  compile_time_purge_matching: [
    [level_lower_than: :warning]
  ]

# ExUnit configuration
config :ex_unit,
  capture_log: true,
  assert_receive_timeout: 2_000,
  refute_receive_timeout: 100

# Bypass configuration
config :bypass,
  adapter: Plug.Cowboy,
  port: 0  # Use random available port

# Specific test environment variables
config :vsm_connections, :test_env,
  ci: System.get_env("CI") == "true",
  coverage: System.get_env("COVERAGE") == "true",
  benchmark: System.get_env("BENCHMARK") == "true"
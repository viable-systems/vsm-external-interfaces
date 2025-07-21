import Config

# Configuration for VSM External Interfaces

config :vsm_external_interfaces,
  # Adapter ports
  http_port: 4000,
  websocket_port: 4001,
  grpc_port: 50051,
  
  # VSM core connection
  vsm_host: "localhost",
  vsm_port: 9000,
  
  # Protocol adapter settings
  adapters: %{
    http: %{
      timeout: 30_000,
      pool_size: 100,
      max_connections: 1000
    },
    websocket: %{
      heartbeat_interval: 30_000,
      max_channels_per_socket: 100
    },
    grpc: %{
      max_receive_message_length: 4 * 1024 * 1024,
      max_send_message_length: 4 * 1024 * 1024,
      keepalive_time: 30_000
    }
  },
  
  # Translation settings
  translation: %{
    json: %{
      validate_schemas: true,
      strip_metadata: false
    }
  }

# Phoenix WebSocket endpoint configuration
config :vsm_external_interfaces, VsmExternalInterfaces.Adapters.WebSocket,
  url: [host: "localhost"],
  secret_key_base: "your-secret-key-base-here-replace-in-production",
  render_errors: [view: VsmExternalInterfaces.ErrorView, accepts: ~w(json)],
  pubsub_server: VsmExternalInterfaces.PubSub,
  live_view: [signing_salt: "your-signing-salt"]

# Phoenix PubSub configuration
config :phoenix, :json_library, Jason

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :system_id, :adapter]

# Telemetry configuration
config :telemetry,
  handlers: [
    {VsmExternalInterfaces.Telemetry, :handle_event, []}
  ]

# Import environment specific config
import_config "#{config_env()}.exs"
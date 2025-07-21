import Config

# Production configuration

config :vsm_external_interfaces,
  # Production ports from environment variables
  http_port: System.get_env("HTTP_PORT", "4000") |> String.to_integer(),
  websocket_port: System.get_env("WS_PORT", "4001") |> String.to_integer(),
  grpc_port: System.get_env("GRPC_PORT", "50051") |> String.to_integer(),
  
  # VSM core connection from environment
  vsm_host: System.get_env("VSM_HOST", "vsm-core"),
  vsm_port: System.get_env("VSM_PORT", "9000") |> String.to_integer()

# WebSocket endpoint configuration for production
config :vsm_external_interfaces, VsmExternalInterfaces.Adapters.WebSocket,
  url: [host: System.get_env("HOST", "localhost"), port: 443, scheme: "https"],
  check_origin: [
    "https://yourdomain.com",
    "https://api.yourdomain.com"
  ],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || 
    raise("SECRET_KEY_BASE environment variable is not set"),
  server: true

# Logger configuration for production
config :logger, level: :info

# Runtime configuration
config :vsm_external_interfaces,
  ssl: [
    port: 443,
    cipher_suite: :strong,
    keyfile: System.get_env("SSL_KEY_PATH"),
    certfile: System.get_env("SSL_CERT_PATH")
  ]
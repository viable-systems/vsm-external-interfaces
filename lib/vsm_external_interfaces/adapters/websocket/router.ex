defmodule VsmExternalInterfaces.Adapters.WebSocket.Router do
  @moduledoc """
  Basic router for WebSocket endpoint health checks and routing.
  """
  
  use Plug.Router
  
  plug :match
  plug :dispatch
  
  # WebSocket health check endpoint
  get "/ws-health" do
    health_status = %{
      status: "healthy",
      service: "websocket",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      socket_path: "/socket",
      channels: %{
        "system:*" => "VSM System Channel",
        "events:*" => "VSM Events Channel"
      }
    }
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health_status))
  end
  
  # Basic info endpoint
  get "/" do
    info = %{
      service: "VSM External Interfaces WebSocket",
      version: "1.0.0",
      socket_url: "ws://#{conn.host}:#{conn.port}/socket",
      channels: [
        "system:system_id",
        "events:global", 
        "events:system_id"
      ],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(info))
  end
  
  match _ do
    send_resp(conn, 404, "WebSocket endpoint not found")
  end
end
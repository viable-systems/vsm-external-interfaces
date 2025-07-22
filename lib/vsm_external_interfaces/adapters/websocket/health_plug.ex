defmodule VsmExternalInterfaces.Adapters.WebSocket.HealthPlug do
  @moduledoc """
  Health check plug for WebSocket endpoint.
  """
  
  import Plug.Conn
  
  def init(opts), do: opts
  
  def call(conn, _opts) do
    # Check WebSocket endpoint health
    endpoint_health = if Process.whereis(VsmExternalInterfaces.Adapters.WebSocket) do
      "active"
    else
      "inactive"
    end
    
    # Check PubSub health
    pubsub_health = if Process.whereis(VsmExternalInterfaces.PubSub) do
      "active" 
    else
      "inactive"
    end
    
    # Check VSM Bridge health
    bridge_health = if Process.whereis(VsmExternalInterfaces.Integrations.VsmBridge) do
      "active"
    else
      "inactive"
    end
    
    health_status = %{
      status: if endpoint_health == "active" && pubsub_health == "active" do
        "healthy"
      else
        "degraded"
      end,
      services: %{
        websocket_endpoint: endpoint_health,
        pubsub: pubsub_health,
        vsm_bridge: bridge_health
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime: :erlang.statistics(:uptime) |> elem(0)
    }
    
    status_code = if health_status.status == "healthy", do: 200, else: 503
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(health_status))
    |> halt()
  end
end
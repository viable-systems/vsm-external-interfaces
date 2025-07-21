defmodule VsmExternalInterfaces.Adapters.HTTP do
  @moduledoc """
  HTTP REST adapter for VSM external interfaces.
  
  Provides RESTful endpoints for interacting with VSM systems, including:
  - System health checks
  - Message sending and routing
  - System queries and state retrieval
  - Algedonic alert triggering
  """
  
  use Plug.Router
  use Plug.ErrorHandler
  
  alias VsmExternalInterfaces.Integrations.VsmBridge
  alias VsmExternalInterfaces.Translators.JsonTranslator
  
  require Logger
  
  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch
  
  # Health check endpoint
  get "/health" do
    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      adapters: %{
        http: "active",
        websocket: check_websocket_health(),
        grpc: check_grpc_health()
      }
    }
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health_status))
  end
  
  # Get all systems
  get "/systems" do
    case VsmBridge.list_systems() do
      {:ok, systems} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{systems: systems}))
      
      {:error, reason} ->
        send_error(conn, 500, "Failed to retrieve systems", reason)
    end
  end
  
  # Get specific system
  get "/systems/:system_id" do
    case VsmBridge.get_system(system_id) do
      {:ok, system} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(system))
      
      {:error, :not_found} ->
        send_error(conn, 404, "System not found", system_id)
      
      {:error, reason} ->
        send_error(conn, 500, "Failed to retrieve system", reason)
    end
  end
  
  # Send message to system
  post "/systems/:system_id/messages" do
    with {:ok, message_data} <- validate_message(conn.body_params),
         {:ok, vsm_message} <- JsonTranslator.to_vsm_message(message_data),
         {:ok, result} <- VsmBridge.send_message(system_id, vsm_message) do
      
      :telemetry.execute(
        [:vsm_external_interfaces, :http, :message_sent],
        %{count: 1},
        %{system_id: system_id, channel: vsm_message.channel}
      )
      
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{
        status: "sent",
        message_id: result.message_id,
        timestamp: result.timestamp
      }))
    else
      {:error, :validation_failed, errors} ->
        send_error(conn, 400, "Invalid message format", errors)
      
      {:error, reason} ->
        send_error(conn, 500, "Failed to send message", reason)
    end
  end
  
  # Trigger algedonic alert
  post "/algedonic/alert" do
    with {:ok, alert_data} <- validate_alert(conn.body_params),
         {:ok, result} <- VsmBridge.trigger_algedonic(alert_data) do
      
      :telemetry.execute(
        [:vsm_external_interfaces, :http, :algedonic_triggered],
        %{count: 1, severity: alert_data["severity"] || "high"},
        %{}
      )
      
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{
        status: "triggered",
        alert_id: result.alert_id,
        propagated_to: result.affected_systems
      }))
    else
      {:error, :validation_failed, errors} ->
        send_error(conn, 400, "Invalid alert format", errors)
      
      {:error, reason} ->
        send_error(conn, 500, "Failed to trigger alert", reason)
    end
  end
  
  # Query system state
  get "/systems/:system_id/state" do
    with {:ok, state} <- VsmBridge.get_system_state(system_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(state))
    else
      {:error, :not_found} ->
        send_error(conn, 404, "System not found", system_id)
      
      {:error, reason} ->
        send_error(conn, 500, "Failed to retrieve state", reason)
    end
  end
  
  match _ do
    send_error(conn, 404, "Endpoint not found", conn.request_path)
  end
  
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
    Logger.error("Unhandled error in HTTP adapter: #{inspect(reason)}")
    send_error(conn, 500, "Internal server error", "An unexpected error occurred")
  end
  
  # Private functions
  
  defp validate_message(params) do
    required_fields = ["type", "payload", "channel"]
    
    case check_required_fields(params, required_fields) do
      :ok -> {:ok, params}
      {:error, missing} -> {:error, :validation_failed, "Missing fields: #{Enum.join(missing, ", ")}"}
    end
  end
  
  defp validate_alert(params) do
    required_fields = ["message", "source"]
    
    case check_required_fields(params, required_fields) do
      :ok -> {:ok, params}
      {:error, missing} -> {:error, :validation_failed, "Missing fields: #{Enum.join(missing, ", ")}"}
    end
  end
  
  defp check_required_fields(params, fields) do
    missing = Enum.filter(fields, &(not Map.has_key?(params, &1)))
    
    if Enum.empty?(missing) do
      :ok
    else
      {:error, missing}
    end
  end
  
  defp send_error(conn, status, message, details \\ nil) do
    error = %{
      error: message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    error = if details, do: Map.put(error, :details, details), else: error
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(error))
  end
  
  defp check_websocket_health do
    # Check if Phoenix endpoint is running
    if Process.whereis(VsmExternalInterfaces.Endpoint) do
      "active"
    else
      "inactive"
    end
  end
  
  defp check_grpc_health do
    # Check if gRPC server is running
    if Process.whereis(VsmExternalInterfaces.Adapters.GRPC.Server) do
      "active"
    else
      "inactive"
    end
  end
end
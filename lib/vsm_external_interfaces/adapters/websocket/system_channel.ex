defmodule VsmExternalInterfaces.Adapters.WebSocket.SystemChannel do
  @moduledoc """
  Phoenix Channel for real-time VSM system interactions.
  
  Provides bidirectional communication for:
  - System state subscriptions
  - Real-time message exchange
  - Event streaming
  - System control commands
  """
  
  use Phoenix.Channel
  
  alias VsmExternalInterfaces.Integrations.VsmBridge
  alias VsmExternalInterfaces.Translators.JsonTranslator
  
  require Logger
  
  @impl true
  def join("system:" <> system_id, params, socket) do
    case VsmBridge.get_system(system_id) do
      {:ok, system} ->
        # Subscribe to system events
        :ok = VsmBridge.subscribe_to_system(system_id, self())
        
        socket = socket
        |> assign(:system_id, system_id)
        |> assign(:subscriptions, [system_id])
        
        {:ok, %{system: system, status: "connected"}, socket}
      
      {:error, :not_found} ->
        {:error, %{reason: "System not found"}}
      
      {:error, reason} ->
        Logger.error("Failed to join system channel: #{inspect(reason)}")
        {:error, %{reason: "Failed to connect to system"}}
    end
  end
  
  @impl true
  def handle_in("message:send", %{"message" => message_data}, socket) do
    system_id = socket.assigns.system_id
    
    case send_message_to_system(system_id, message_data) do
      {:ok, result} ->
        # Broadcast the message to all subscribers
        broadcast!(socket, "message:sent", %{
          message_id: result.message_id,
          timestamp: result.timestamp,
          status: "sent"
        })
        
        {:reply, {:ok, result}, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end
  
  @impl true
  def handle_in("state:request", _params, socket) do
    system_id = socket.assigns.system_id
    
    case VsmBridge.get_system_state(system_id) do
      {:ok, state} ->
        {:reply, {:ok, state}, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end
  
  @impl true
  def handle_in("subscribe:events", %{"event_types" => types}, socket) do
    system_id = socket.assigns.system_id
    
    case VsmBridge.subscribe_to_events(system_id, types, self()) do
      :ok ->
        socket = update_in(socket.assigns.subscriptions, &(&1 ++ types))
        {:reply, {:ok, %{subscribed: types}}, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end
  
  @impl true
  def handle_in("command:execute", %{"command" => command, "params" => params}, socket) do
    system_id = socket.assigns.system_id
    
    case execute_system_command(system_id, command, params) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end
  
  @impl true
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: :os.system_time(:millisecond)}}, socket}
  end
  
  @impl true
  def handle_info({:vsm_event, event}, socket) do
    # Forward VSM events to the client
    push(socket, "event:received", %{
      type: event.type,
      payload: event.payload,
      timestamp: event.timestamp,
      source: event.source
    })
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:vsm_state_change, state_change}, socket) do
    # Forward state changes to the client
    push(socket, "state:changed", %{
      system_id: socket.assigns.system_id,
      changes: state_change.changes,
      timestamp: state_change.timestamp
    })
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:vsm_message, message}, socket) do
    # Forward messages to the client
    case JsonTranslator.from_vsm_message(message) do
      {:ok, json_message} ->
        push(socket, "message:received", json_message)
      
      {:error, reason} ->
        Logger.error("Failed to translate VSM message: #{inspect(reason)}")
    end
    
    {:noreply, socket}
  end
  
  @impl true
  def terminate(reason, socket) do
    # Unsubscribe from all events
    system_id = socket.assigns[:system_id]
    
    if system_id do
      VsmBridge.unsubscribe_from_system(system_id, self())
      Logger.info("WebSocket client disconnected from system #{system_id}: #{inspect(reason)}")
    end
    
    :ok
  end
  
  # Private functions
  
  defp send_message_to_system(system_id, message_data) do
    with {:ok, vsm_message} <- JsonTranslator.to_vsm_message(message_data),
         {:ok, result} <- VsmBridge.send_message(system_id, vsm_message) do
      
      :telemetry.execute(
        [:vsm_external_interfaces, :websocket, :message_sent],
        %{count: 1},
        %{system_id: system_id, channel: vsm_message.channel}
      )
      
      {:ok, result}
    end
  end
  
  defp execute_system_command(system_id, command, params) do
    case command do
      "start" -> VsmBridge.start_system(system_id, params)
      "stop" -> VsmBridge.stop_system(system_id, params)
      "restart" -> VsmBridge.restart_system(system_id, params)
      "configure" -> VsmBridge.configure_system(system_id, params)
      _ -> {:error, :unknown_command}
    end
  end
  
  defp format_error(:not_found), do: "Resource not found"
  defp format_error(:unauthorized), do: "Unauthorized"
  defp format_error(:timeout), do: "Operation timed out"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
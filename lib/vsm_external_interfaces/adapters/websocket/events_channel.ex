defmodule VsmExternalInterfaces.Adapters.WebSocket.EventsChannel do
  @moduledoc """
  Phoenix Channel for VSM event streaming and broadcasting.
  
  Provides real-time event distribution for:
  - System-wide event feeds
  - Event filtering and routing
  - Broadcast messaging
  - Event aggregation
  """
  
  use Phoenix.Channel
  
  alias VsmExternalInterfaces.Integrations.VsmBridge
  
  require Logger
  
  @impl true
  def join("events:" <> topic, params, socket) do
    case topic do
      "global" ->
        # Subscribe to global events
        :ok = VsmBridge.subscribe_to_events("*", ["*"], self())
        
        socket = socket
        |> assign(:topic, "global")
        |> assign(:filters, params["filters"] || [])
        
        {:ok, %{topic: "global", status: "subscribed"}, socket}
      
      system_id ->
        # Subscribe to specific system events
        case VsmBridge.get_system(system_id) do
          {:ok, _system} ->
            event_types = params["event_types"] || ["*"]
            :ok = VsmBridge.subscribe_to_events(system_id, event_types, self())
            
            socket = socket
            |> assign(:topic, system_id)
            |> assign(:event_types, event_types)
            |> assign(:filters, params["filters"] || [])
            
            {:ok, %{topic: system_id, event_types: event_types}, socket}
          
          {:error, :not_found} ->
            {:error, %{reason: "System not found"}}
        end
    end
  end
  
  @impl true
  def handle_in("filter:update", %{"filters" => filters}, socket) do
    socket = assign(socket, :filters, filters)
    {:reply, {:ok, %{filters: filters}}, socket}
  end
  
  @impl true
  def handle_in("event:broadcast", %{"event" => event_data}, socket) do
    # Allow clients to broadcast custom events
    case broadcast_event(event_data, socket) do
      :ok ->
        {:reply, {:ok, %{status: "broadcasted"}}, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end
  
  @impl true
  def handle_in("subscription:modify", %{"action" => action} = params, socket) do
    case action do
      "add_event_types" ->
        event_types = params["event_types"] || []
        topic = socket.assigns.topic
        
        case VsmBridge.subscribe_to_events(topic, event_types, self()) do
          :ok ->
            current_types = socket.assigns[:event_types] || []
            new_types = Enum.uniq(current_types ++ event_types)
            socket = assign(socket, :event_types, new_types)
            
            {:reply, {:ok, %{event_types: new_types}}, socket}
          
          error ->
            {:reply, error, socket}
        end
      
      "remove_event_types" ->
        # Implementation for removing event type subscriptions
        {:reply, {:ok, %{status: "not_implemented"}}, socket}
      
      _ ->
        {:reply, {:error, %{reason: "Unknown action"}}, socket}
    end
  end
  
  @impl true
  def handle_info({:vsm_event, event}, socket) do
    # Apply filters before sending to client
    if should_forward_event?(event, socket.assigns[:filters]) do
      push(socket, "event", %{
        id: event.id || generate_event_id(),
        type: event.type,
        source: event.source,
        payload: event.payload,
        timestamp: event.timestamp |> DateTime.to_iso8601(),
        metadata: event.metadata || %{}
      })
    end
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:broadcast_event, event}, socket) do
    # Handle broadcasted events from other channels/processes
    push(socket, "broadcast", %{
      type: "custom_event",
      event: event,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
    
    {:noreply, socket}
  end
  
  @impl true
  def terminate(reason, socket) do
    topic = socket.assigns[:topic]
    
    if topic && topic != "global" do
      VsmBridge.unsubscribe_from_system(topic, self())
    end
    
    Logger.info("Events channel terminated for topic #{topic}: #{inspect(reason)}")
    :ok
  end
  
  # Private functions
  
  defp should_forward_event?(_event, []), do: true
  defp should_forward_event?(event, filters) do
    Enum.all?(filters, fn filter ->
      apply_filter(event, filter)
    end)
  end
  
  defp apply_filter(event, %{"type" => type_filter}) do
    event.type == type_filter
  end
  
  defp apply_filter(event, %{"source" => source_filter}) do
    event.source == source_filter
  end
  
  defp apply_filter(event, %{"severity" => severity_filter}) do
    event_severity = get_in(event.payload, ["severity"]) || 
                    get_in(event.metadata, ["severity"]) ||
                    "normal"
    event_severity == severity_filter
  end
  
  defp apply_filter(event, %{"contains" => text}) do
    event_text = Jason.encode!(event) |> String.downcase()
    String.contains?(event_text, String.downcase(text))
  end
  
  defp apply_filter(_event, _filter), do: true
  
  defp broadcast_event(event_data, socket) do
    # Create a custom event and broadcast to all subscribers in the same topic
    topic = socket.assigns.topic
    
    event = %{
      type: event_data["type"] || "custom",
      payload: event_data["payload"] || %{},
      source: "client_#{socket.assigns[:user_id] || "anonymous"}",
      timestamp: DateTime.utc_now()
    }
    
    # Broadcast to all subscribers of this topic
    Phoenix.PubSub.broadcast(
      VsmExternalInterfaces.PubSub,
      "events:#{topic}",
      {:broadcast_event, event}
    )
    
    :ok
  end
  
  defp generate_event_id do
    "evt_#{:rand.uniform(1_000_000)}_#{System.os_time(:microsecond)}"
  end
end
defmodule VsmExternalInterfaces.GoldrushIntegration do
  @moduledoc """
  Integration with vsm-goldrush for high-performance event pattern matching.
  
  Monitors external interface events for VSM cybernetic patterns like:
  - High latency responses (variety explosion)
  - Connection failures (channel breakdown)
  - Algedonic signal patterns
  - Rate limit violations
  """
  
  use GenServer
  require Logger
  
  @patterns %{
    # HTTP adapter patterns
    high_http_latency: %{
      field: :duration,
      operator: :gt,
      value: 5000  # 5 seconds
    },
    http_error_rate: %{
      field: :status,
      operator: :gte,
      value: 500
    },
    
    # WebSocket patterns
    ws_connection_surge: %{
      field: :connections_count,
      operator: :gt,
      value: 1000
    },
    ws_disconnection_pattern: %{
      field: :disconnect_reason,
      operator: :eq,
      value: :timeout
    },
    
    # gRPC patterns
    grpc_stream_timeout: %{
      field: :stream_duration,
      operator: :gt,
      value: 30000  # 30 seconds
    },
    grpc_message_size: %{
      field: :message_size,
      operator: :gt,
      value: 4_194_304  # 4MB
    },
    
    # Algedonic patterns
    algedonic_cascade: %{
      field: :severity,
      operator: :eq,
      value: "critical"
    },
    emergency_bypass: %{
      field: :channel,
      operator: :eq,
      value: :algedonic
    }
  }
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    # Only initialize if vsm_goldrush is available
    if Code.ensure_loaded?(VsmGoldrush) do
      Logger.info("Initializing Goldrush integration for VSM external interfaces")
      
      # Initialize goldrush
      VsmGoldrush.init()
      
      # Compile all patterns
      Enum.each(@patterns, fn {name, pattern} ->
        case VsmGoldrush.compile_pattern(name, pattern) do
          {:ok, _} ->
            Logger.info("Compiled goldrush pattern: #{name}")
          
          {:error, reason} ->
            Logger.error("Failed to compile pattern #{name}: #{inspect(reason)}")
        end
      end)
      
      # Subscribe to telemetry events
      :telemetry.attach_many(
        "vsm-external-interfaces-goldrush",
        [
          [:vsm_external_interfaces, :http, :message_sent],
          [:vsm_external_interfaces, :websocket, :message_sent],
          [:vsm_external_interfaces, :grpc, :message_sent],
          [:vsm_bridge, :message_sent],
          [:vsm_bridge, :algedonic_triggered]
        ],
        &handle_telemetry_event/4,
        nil
      )
      
      {:ok, %{enabled: true, patterns_compiled: Map.keys(@patterns)}}
    else
      Logger.info("VsmGoldrush not available, skipping pattern compilation")
      {:ok, %{enabled: false}}
    end
  end
  
  @doc """
  Process an event through all relevant goldrush patterns.
  """
  def process_event(event) do
    GenServer.cast(__MODULE__, {:process_event, event})
  end
  
  @impl true
  def handle_cast({:process_event, event}, %{enabled: true} = state) do
    # Check event against all patterns
    Enum.each(@patterns, fn {pattern_name, _} ->
      case VsmGoldrush.process_event(pattern_name, event) do
        {:match, matched_event} ->
          handle_pattern_match(pattern_name, matched_event)
        
        :no_match ->
          :ok
      end
    end)
    
    {:noreply, state}
  end
  
  def handle_cast({:process_event, _event}, %{enabled: false} = state) do
    # Goldrush not enabled, skip processing
    {:noreply, state}
  end
  
  # Telemetry event handler
  defp handle_telemetry_event(event_name, measurements, metadata, _config) do
    # Convert telemetry event to goldrush event format
    event = Map.merge(measurements, metadata)
    |> Map.put(:event_type, event_name)
    |> Map.put(:timestamp, System.system_time(:millisecond))
    
    # Process through goldrush
    process_event(event)
  end
  
  # Pattern match handlers
  defp handle_pattern_match(:high_http_latency, event) do
    Logger.warning("High HTTP latency detected: #{event.duration}ms for #{event[:path]}")
    
    # Could trigger algedonic signal if latency is extreme
    if event.duration > 10000 do
      trigger_algedonic_signal("HTTP performance degradation", event)
    end
  end
  
  defp handle_pattern_match(:http_error_rate, event) do
    Logger.error("HTTP error detected: #{event.status} for #{event[:path]}")
  end
  
  defp handle_pattern_match(:ws_connection_surge, event) do
    Logger.warning("WebSocket connection surge: #{event.connections_count} active connections")
    
    # Implement variety management
    if event.connections_count > 5000 do
      trigger_variety_management("websocket_connections", event)
    end
  end
  
  defp handle_pattern_match(:algedonic_cascade, event) do
    Logger.error("Algedonic cascade detected: #{inspect(event)}")
    
    # Track pattern statistics
    if Code.ensure_loaded?(VsmGoldrush) do
      stats = VsmGoldrush.get_stats(:algedonic_cascade)
      Logger.info("Algedonic cascade stats: #{inspect(stats)}")
    end
  end
  
  defp handle_pattern_match(pattern, event) do
    Logger.info("Pattern match: #{pattern} - #{inspect(event)}")
  end
  
  # VSM response actions
  defp trigger_algedonic_signal(message, event) do
    alert_data = %{
      "message" => message,
      "source" => "external_interfaces_monitor",
      "severity" => "high",
      "event_data" => event
    }
    
    # Send through VSM bridge
    with {:ok, bridge_pid} <- find_vsm_bridge() do
      GenServer.call(bridge_pid, {:trigger_algedonic, alert_data})
    end
  end
  
  defp trigger_variety_management(resource, event) do
    Logger.warning("Triggering variety management for #{resource}: #{inspect(event)}")
    
    # Implement variety attenuation strategies
    # This could involve rate limiting, connection throttling, etc.
  end
  
  defp find_vsm_bridge do
    case Process.whereis(VsmExternalInterfaces.Integrations.VsmBridge) do
      nil -> {:error, :bridge_not_found}
      pid -> {:ok, pid}
    end
  end
  
  @doc """
  Get pattern matching statistics.
  """
  def get_pattern_stats do
    if Code.ensure_loaded?(VsmGoldrush) do
      Enum.map(@patterns, fn {name, _} ->
        {name, VsmGoldrush.get_stats(name)}
      end)
      |> Enum.into(%{})
    else
      {:error, :goldrush_not_available}
    end
  end
end
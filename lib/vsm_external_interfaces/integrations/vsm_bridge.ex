defmodule VsmExternalInterfaces.Integrations.VsmBridge do
  @moduledoc """
  Bridge module for integrating with VSM core systems.
  
  Provides a unified interface for:
  - System discovery and management
  - Message routing to VSM subsystems
  - Event subscription and forwarding
  - State synchronization
  - Algedonic signal handling
  """
  
  use GenServer
  
  alias VsmCore.{System, Message, Event}
  alias VsmConnections.ConnectionManager
  
  require Logger
  
  # Client API
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Lists all available VSM systems.
  """
  def list_systems do
    GenServer.call(__MODULE__, :list_systems)
  end
  
  @doc """
  Gets a specific system by ID.
  """
  def get_system(system_id) do
    GenServer.call(__MODULE__, {:get_system, system_id})
  end
  
  @doc """
  Sends a message to a specific system.
  """
  def send_message(system_id, message) do
    GenServer.call(__MODULE__, {:send_message, system_id, message})
  end
  
  @doc """
  Gets the current state of a system.
  """
  def get_system_state(system_id) do
    GenServer.call(__MODULE__, {:get_system_state, system_id})
  end
  
  @doc """
  Subscribes to system events.
  """
  def subscribe_to_system(system_id, pid) do
    GenServer.call(__MODULE__, {:subscribe, system_id, pid})
  end
  
  @doc """
  Subscribes to specific event types.
  """
  def subscribe_to_events(system_id, event_types, pid) do
    GenServer.call(__MODULE__, {:subscribe_events, system_id, event_types, pid})
  end
  
  @doc """
  Unsubscribes from system events.
  """
  def unsubscribe_from_system(system_id, pid) do
    GenServer.call(__MODULE__, {:unsubscribe, system_id, pid})
  end
  
  @doc """
  Triggers an algedonic alert.
  """
  def trigger_algedonic(alert_data) do
    GenServer.call(__MODULE__, {:trigger_algedonic, alert_data})
  end
  
  @doc """
  System control operations.
  """
  def start_system(system_id, params \\ %{}) do
    GenServer.call(__MODULE__, {:control_system, system_id, :start, params})
  end
  
  def stop_system(system_id, params \\ %{}) do
    GenServer.call(__MODULE__, {:control_system, system_id, :stop, params})
  end
  
  def restart_system(system_id, params \\ %{}) do
    GenServer.call(__MODULE__, {:control_system, system_id, :restart, params})
  end
  
  def configure_system(system_id, params) do
    GenServer.call(__MODULE__, {:control_system, system_id, :configure, params})
  end
  
  # Server callbacks
  
  @impl true
  def init(opts) do
    # Initialize connection to VSM core
    vsm_host = Keyword.get(opts, :vsm_host, "localhost")
    vsm_port = Keyword.get(opts, :vsm_port, 9000)
    
    state = %{
      systems: %{},
      subscriptions: %{},
      event_subscriptions: %{},
      connection: nil,
      vsm_config: %{host: vsm_host, port: vsm_port},
      message_cache: :ets.new(:vsm_message_cache, [:set, :private])
    }
    
    # Schedule connection attempt
    Process.send_after(self(), :connect_to_vsm, 100)
    
    {:ok, state}
  end
  
  @impl true
  def handle_call(:list_systems, _from, state) do
    systems = Map.values(state.systems)
    {:reply, {:ok, systems}, state}
  end
  
  @impl true
  def handle_call({:get_system, system_id}, _from, state) do
    case Map.get(state.systems, system_id) do
      nil -> {:reply, {:error, :not_found}, state}
      system -> {:reply, {:ok, system}, state}
    end
  end
  
  @impl true
  def handle_call({:send_message, system_id, message}, _from, state) do
    case route_message(system_id, message, state) do
      {:ok, result} ->
        # Cache the message
        :ets.insert(state.message_cache, {message.id, message})
        
        # Track metrics
        :telemetry.execute(
          [:vsm_bridge, :message_sent],
          %{count: 1},
          %{system_id: system_id, channel: message.channel}
        )
        
        {:reply, {:ok, result}, state}
      
      error ->
        {:reply, error, state}
    end
  end
  
  @impl true
  def handle_call({:get_system_state, system_id}, _from, state) do
    case Map.get(state.systems, system_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      
      system ->
        # Query the actual system state
        case query_system_state(system, state) do
          {:ok, system_state} ->
            {:reply, {:ok, system_state}, state}
          
          error ->
            {:reply, error, state}
        end
    end
  end
  
  @impl true
  def handle_call({:subscribe, system_id, pid}, _from, state) do
    Process.monitor(pid)
    
    subscriptions = Map.update(
      state.subscriptions,
      system_id,
      [pid],
      &[pid | &1]
    )
    
    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end
  
  @impl true
  def handle_call({:subscribe_events, system_id, event_types, pid}, _from, state) do
    Process.monitor(pid)
    
    event_subs = Enum.reduce(event_types, state.event_subscriptions, fn type, acc ->
      Map.update(acc, {system_id, type}, [pid], &[pid | &1])
    end)
    
    {:reply, :ok, %{state | event_subscriptions: event_subs}}
  end
  
  @impl true
  def handle_call({:unsubscribe, system_id, pid}, _from, state) do
    subscriptions = Map.update(
      state.subscriptions,
      system_id,
      [],
      &List.delete(&1, pid)
    )
    
    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end
  
  @impl true
  def handle_call({:trigger_algedonic, alert_data}, _from, state) do
    case broadcast_algedonic_alert(alert_data, state) do
      {:ok, affected_systems} ->
        result = %{
          alert_id: generate_alert_id(),
          affected_systems: affected_systems,
          timestamp: DateTime.utc_now()
        }
        
        {:reply, {:ok, result}, state}
      
      error ->
        {:reply, error, state}
    end
  end
  
  @impl true
  def handle_call({:control_system, system_id, operation, params}, _from, state) do
    case Map.get(state.systems, system_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      
      system ->
        case perform_system_control(system, operation, params, state) do
          {:ok, result} ->
            {:reply, {:ok, result}, state}
          
          error ->
            {:reply, error, state}
        end
    end
  end
  
  @impl true
  def handle_info(:connect_to_vsm, state) do
    case establish_vsm_connection(state.vsm_config) do
      {:ok, connection} ->
        Logger.info("Connected to VSM core")
        
        # Discover available systems
        {:ok, systems} = discover_systems(connection)
        
        state = %{state | 
          connection: connection,
          systems: Map.new(systems, &{&1.id, &1})
        }
        
        {:noreply, state}
      
      {:error, reason} ->
        Logger.error("Failed to connect to VSM core: #{inspect(reason)}")
        # Retry connection
        Process.send_after(self(), :connect_to_vsm, 5000)
        {:noreply, state}
    end
  end
  
  @impl true
  def handle_info({:vsm_event, event}, state) do
    # Forward event to subscribers
    forward_event(event, state)
    {:noreply, state}
  end
  
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up subscriptions for dead process
    subscriptions = Enum.reduce(state.subscriptions, %{}, fn {system_id, pids}, acc ->
      remaining = List.delete(pids, pid)
      if Enum.empty?(remaining) do
        acc
      else
        Map.put(acc, system_id, remaining)
      end
    end)
    
    event_subs = Enum.reduce(state.event_subscriptions, %{}, fn {{system_id, type}, pids}, acc ->
      remaining = List.delete(pids, pid)
      if Enum.empty?(remaining) do
        acc
      else
        Map.put(acc, {system_id, type}, remaining)
      end
    end)
    
    {:noreply, %{state | subscriptions: subscriptions, event_subscriptions: event_subs}}
  end
  
  # Private functions
  
  defp route_message(system_id, message, state) do
    case Map.get(state.systems, system_id) do
      nil ->
        {:error, :system_not_found}
      
      system ->
        # Route based on channel
        subsystem = determine_target_subsystem(message.channel, message.type)
        
        enriched_message = %{message | 
          to: "#{system_id}/#{subsystem}",
          metadata: Map.put(message.metadata || %{}, "routed_by", "vsm_bridge")
        }
        
        # Send through connection
        case send_through_connection(enriched_message, state.connection) do
          :ok ->
            {:ok, %{
              message_id: enriched_message.id,
              timestamp: enriched_message.timestamp
            }}
          
          error ->
            error
        end
    end
  end
  
  defp determine_target_subsystem(channel, type) do
    case {channel, type} do
      {:algedonic, _} -> "system5"  # Policy level for emergencies
      {:command, _} -> "system3"     # Control
      {:coordination, _} -> "system2" # Anti-oscillation
      {:resource_bargain, _} -> "system3" # Resource allocation
      {:temporal, :intelligence} -> "system4" # Intelligence
      {:temporal, :policy} -> "system5" # Policy
      {:temporal, _} -> "system1" # Default operations
    end
  end
  
  defp query_system_state(system, state) do
    # Mock implementation - would query actual system
    {:ok, %{
      system_id: system.id,
      status: system.status,
      subsystems: %{
        system1: %{status: :active, load: 75},
        system2: %{status: :active, coordination_active: true},
        system3: %{status: :active, resources_allocated: 85},
        system4: %{status: :active, scanning: true},
        system5: %{status: :active, policy_version: "1.2.0"}
      },
      metrics: %{
        messages_processed: :rand.uniform(10000),
        average_latency_ms: :rand.uniform(100),
        error_rate: :rand.uniform(5) / 100
      },
      timestamp: DateTime.utc_now()
    }}
  end
  
  defp broadcast_algedonic_alert(alert_data, state) do
    alert = %Message{
      id: generate_alert_id(),
      type: :algedonic_alert,
      channel: :algedonic,
      from: alert_data["source"] || "external",
      to: "all/system5",  # Algedonic goes directly to System 5
      payload: %{
        message: alert_data["message"],
        severity: alert_data["severity"] || "high",
        metadata: alert_data
      },
      timestamp: DateTime.utc_now()
    }
    
    # Send to all systems
    affected = Enum.map(state.systems, fn {id, _system} ->
      send_through_connection(alert, state.connection)
      id
    end)
    
    {:ok, affected}
  end
  
  defp perform_system_control(system, operation, params, state) do
    # Mock implementation
    case operation do
      :start ->
        {:ok, %{system_id: system.id, status: :starting}}
      
      :stop ->
        {:ok, %{system_id: system.id, status: :stopping}}
      
      :restart ->
        {:ok, %{system_id: system.id, status: :restarting}}
      
      :configure ->
        {:ok, %{system_id: system.id, configuration: params, status: :configured}}
      
      _ ->
        {:error, :unknown_operation}
    end
  end
  
  defp forward_event(event, state) do
    # Forward to system subscribers
    system_id = event.source
    pids = Map.get(state.subscriptions, system_id, [])
    
    Enum.each(pids, fn pid ->
      send(pid, {:vsm_event, event})
    end)
    
    # Forward to event type subscribers
    event_pids = Map.get(state.event_subscriptions, {system_id, event.type}, [])
    
    Enum.each(event_pids, fn pid ->
      send(pid, {:vsm_event, event})
    end)
  end
  
  defp establish_vsm_connection(config) do
    # Mock connection - would use VsmConnections in real implementation
    {:ok, %{host: config.host, port: config.port, connected: true}}
  end
  
  defp discover_systems(_connection) do
    # Mock system discovery
    systems = [
      %System{
        id: "manufacturing_plant_1",
        name: "Manufacturing Plant 1",
        status: :active,
        metadata: %{location: "Factory A", capacity: 1000}
      },
      %System{
        id: "supply_chain_1", 
        name: "Supply Chain System",
        status: :active,
        metadata: %{regions: ["North", "South"], suppliers: 25}
      },
      %System{
        id: "logistics_1",
        name: "Logistics Network",
        status: :active,
        metadata: %{warehouses: 5, fleet_size: 50}
      }
    ]
    
    {:ok, systems}
  end
  
  defp send_through_connection(_message, _connection) do
    # Mock sending - would use actual connection
    :ok
  end
  
  defp generate_alert_id do
    "alert_#{:rand.uniform(1_000_000)}_#{:os.system_time(:microsecond)}"
  end
end
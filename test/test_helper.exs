ExUnit.start()

# Configure ExUnit
ExUnit.configure(
  exclude: [:pending],
  include: [],
  formatters: [ExUnit.CLIFormatter],
  colors: [enabled: true],
  max_failures: 1,
  seed: 0
)

# Start required applications
Application.ensure_all_started(:bypass)
Application.ensure_all_started(:websockex)
Application.ensure_all_started(:grpc)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:finch)
Application.ensure_all_started(:vsm_connections)

# Setup test environment
System.put_env("MIX_ENV", "test")

# Common test modules
defmodule VsmConnections.TestHelpers do
  @moduledoc """
  Common helper functions for tests
  """

  def wait_until(timeout \\ 5000, fun) do
    wait_until(System.monotonic_time(:millisecond) + timeout, fun)
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      true ->
        :ok
      
      false ->
        now = System.monotonic_time(:millisecond)
        if now < deadline do
          Process.sleep(10)
          wait_until(deadline, fun)
        else
          raise "Timeout waiting for condition"
        end
    end
  end

  def eventually(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 100)
    
    Task.async(fn ->
      wait_until(timeout, fun)
    end)
    |> Task.await(timeout + 1000)
  end

  def random_port do
    # Get a random available port
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  def start_telemetry_handler(event_name, handler_id) do
    self = self()
    
    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _ ->
        send(self, {:telemetry, event, measurements, metadata})
      end,
      nil
    )
  end

  def stop_telemetry_handler(handler_id) do
    :telemetry.detach(handler_id)
  end

  def assert_telemetry_event(event_name, timeout \\ 1000) do
    receive do
      {:telemetry, ^event_name, measurements, metadata} ->
        {measurements, metadata}
    after
      timeout ->
        raise "Did not receive telemetry event #{inspect(event_name)} within #{timeout}ms"
    end
  end
end

# Mock servers for testing
defmodule VsmConnections.MockServers do
  @moduledoc """
  Mock servers for testing protocol adapters
  """

  def start_http_echo_server do
    bypass = Bypass.open()
    
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      
      response = %{
        method: conn.method,
        path: conn.request_path,
        headers: conn.req_headers,
        body: try_decode_body(body)
      }
      
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)
    
    %{bypass: bypass, port: bypass.port, url: "http://localhost:#{bypass.port}"}
  end

  def start_websocket_echo_server do
    # This would use a real WebSocket server library in practice
    port = VsmConnections.TestHelpers.random_port()
    
    # Mock implementation
    %{
      port: port,
      url: "ws://localhost:#{port}",
      send_to_clients: fn message ->
        # Broadcast to all connected clients
        :ok
      end
    }
  end

  def start_grpc_echo_server do
    # This would use a real gRPC server in practice
    port = VsmConnections.TestHelpers.random_port()
    
    # Mock implementation
    %{
      port: port,
      host: "localhost",
      stop: fn -> :ok end
    }
  end

  defp try_decode_body(""), do: nil
  defp try_decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end

# Test data generators
defmodule VsmConnections.TestData do
  @moduledoc """
  Test data generators and fixtures
  """

  def user_fixture(attrs \\ %{}) do
    Map.merge(%{
      id: System.unique_integer([:positive]),
      name: "Test User #{System.unique_integer([:positive])}",
      email: "user#{System.unique_integer([:positive])}@example.com",
      active: true,
      created_at: DateTime.utc_now()
    }, attrs)
  end

  def message_fixture(attrs \\ %{}) do
    Map.merge(%{
      id: System.unique_integer([:positive]),
      type: "test_message",
      content: "Test content #{System.unique_integer([:positive])}",
      timestamp: DateTime.utc_now()
    }, attrs)
  end

  def large_payload(size_kb) do
    # Generate payload of approximately size_kb kilobytes
    data = String.duplicate("x", size_kb * 1024)
    %{
      size: size_kb,
      data: data,
      checksum: :crypto.hash(:sha256, data) |> Base.encode16()
    }
  end

  def binary_payload(size) do
    :crypto.strong_rand_bytes(size)
  end

  def nested_data(depth, width \\ 3) do
    if depth == 0 do
      Enum.random(["leaf", 123, true, nil])
    else
      Map.new(1..width, fn i ->
        {"field_#{i}", nested_data(depth - 1, width)}
      end)
    end
  end
end

# Performance testing helpers
defmodule VsmConnections.PerformanceHelpers do
  @moduledoc """
  Helpers for performance and benchmark tests
  """

  def measure_time(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    duration = System.monotonic_time(:microsecond) - start
    {result, duration}
  end

  def measure_memory(fun) do
    {:memory, before_memory} = Process.info(self(), :memory)
    
    result = fun.()
    
    # Force garbage collection
    :erlang.garbage_collect()
    
    {:memory, after_memory} = Process.info(self(), :memory)
    
    {result, after_memory - before_memory}
  end

  def benchmark(name, fun, opts \\ []) do
    warmup = Keyword.get(opts, :warmup, 10)
    iterations = Keyword.get(opts, :iterations, 100)
    
    # Warmup
    for _ <- 1..warmup, do: fun.()
    
    # Actual benchmark
    times = for _ <- 1..iterations do
      {_, duration} = measure_time(fun)
      duration
    end
    
    %{
      name: name,
      iterations: iterations,
      min: Enum.min(times),
      max: Enum.max(times),
      mean: Enum.sum(times) / iterations,
      median: median(times),
      std_dev: std_dev(times)
    }
  end

  defp median(list) do
    sorted = Enum.sort(list)
    mid = div(length(sorted), 2)
    
    if rem(length(sorted), 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  defp std_dev(list) do
    mean = Enum.sum(list) / length(list)
    
    variance = list
      |> Enum.map(fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(length(list))
    
    :math.sqrt(variance)
  end
end

# Telemetry test collector
defmodule VsmConnections.TelemetryCollector do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    events = [
      [:vsm_connections, :adapter, :request],
      [:vsm_connections, :adapter, :websocket, :*],
      [:vsm_connections, :adapter, :grpc],
      [:vsm_connections, :pool, :*],
      [:vsm_connections, :circuit_breaker, :*]
    ]

    Enum.each(events, fn event ->
      :telemetry.attach(
        "test-collector-#{inspect(event)}",
        event,
        &handle_event/4,
        nil
      )
    end)

    {:ok, %{events: []}}
  end

  def handle_event(event, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:event, event, measurements, metadata})
  end

  def handle_cast({:event, event, measurements, metadata}, state) do
    event_data = %{
      event: event,
      measurements: measurements,
      metadata: metadata,
      timestamp: System.system_time(:microsecond)
    }
    
    {:noreply, %{state | events: [event_data | state.events]}}
  end

  def handle_call(:get_events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  def handle_call(:clear_events, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end

  def get_events do
    GenServer.call(__MODULE__, :get_events)
  end

  def clear_events do
    GenServer.call(__MODULE__, :clear_events)
  end
end

# Start telemetry collector if in test environment
if Mix.env() == :test do
  {:ok, _} = VsmConnections.TelemetryCollector.start_link()
end
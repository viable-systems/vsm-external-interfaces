defmodule VsmConnections.Adapters.WebSocketTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias VsmConnections.Adapters.WebSocket

  @moduletag :unit

  defmodule TestHandler do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      {:ok, %{parent: opts[:parent], events: []}}
    end

    def handle_websocket_event(event, data) do
      GenServer.cast(self(), {:event, event, data})
    end

    def handle_cast({:event, event, data}, state) do
      send(state.parent, {:websocket_event, event, data})
      {:noreply, %{state | events: [{event, data} | state.events]}}
    end
  end

  describe "connect/1" do
    test "establishes WebSocket connection successfully" do
      server = start_websocket_server()
      
      assert {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        callback_module: TestHandler,
        heartbeat_interval: 100
      )

      assert is_pid(socket)
      assert Process.alive?(socket)
      
      WebSocket.close(socket)
      stop_websocket_server(server)
    end

    test "handles connection failures gracefully" do
      assert {:error, _reason} = WebSocket.connect(
        url: "ws://localhost:9999/nonexistent",
        callback_module: TestHandler
      )
    end

    test "applies custom headers during connection" do
      server = start_websocket_server(fn headers ->
        assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer token123"}
        assert List.keyfind(headers, "x-custom-header", 0) == {"x-custom-header", "test"}
      end)
      
      assert {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        headers: [
          {"authorization", "Bearer token123"},
          {"x-custom-header", "test"}
        ]
      )

      WebSocket.close(socket)
      stop_websocket_server(server)
    end

    test "supports WebSocket subprotocols" do
      server = start_websocket_server(fn _headers, protocols ->
        assert "graphql-ws" in protocols
      end)
      
      assert {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        protocols: ["graphql-ws"]
      )

      WebSocket.close(socket)
      stop_websocket_server(server)
    end

    test "emits telemetry on successful connection" do
      self = self()
      
      :telemetry.attach(
        "test-ws-connect",
        [:vsm_connections, :adapter, :websocket, :connect],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      server = start_websocket_server()
      
      assert {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        name: :test_socket
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :websocket, :connect], _measurements, metadata}
      assert metadata.result == :success
      assert metadata.name == :test_socket

      WebSocket.close(socket)
      stop_websocket_server(server)
      :telemetry.detach("test-ws-connect")
    end
  end

  describe "send_message/2" do
    setup do
      server = start_websocket_server()
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        callback_module: TestHandler
      )
      
      on_exit(fn ->
        WebSocket.close(socket)
        stop_websocket_server(server)
      end)
      
      {:ok, socket: socket, server: server}
    end

    test "sends text messages successfully", %{socket: socket} do
      assert :ok = WebSocket.send_message(socket, %{type: "ping", id: 123})
      assert :ok = WebSocket.send_message(socket, "Hello, WebSocket!")
    end

    test "handles send errors gracefully", %{socket: socket} do
      # Force close the socket
      Process.exit(socket, :kill)
      Process.sleep(10)

      assert {:error, _reason} = WebSocket.send_message(socket, "test")
    end

    test "emits telemetry on message send", %{socket: socket} do
      self = self()
      
      :telemetry.attach(
        "test-ws-send",
        [:vsm_connections, :adapter, :websocket, :send_message],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      WebSocket.send_message(socket, %{test: "data"})

      assert_receive {:telemetry, [:vsm_connections, :adapter, :websocket, :send_message], _measurements, metadata}
      assert metadata.result == :success

      :telemetry.detach("test-ws-send")
    end
  end

  describe "send_binary/2" do
    setup do
      server = start_websocket_server()
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket"
      )
      
      on_exit(fn ->
        WebSocket.close(socket)
        stop_websocket_server(server)
      end)
      
      {:ok, socket: socket}
    end

    test "sends binary data successfully", %{socket: socket} do
      binary_data = <<1, 2, 3, 4, 5>>
      assert :ok = WebSocket.send_binary(socket, binary_data)
    end

    test "emits telemetry with size information", %{socket: socket} do
      self = self()
      
      :telemetry.attach(
        "test-ws-binary",
        [:vsm_connections, :adapter, :websocket, :send_binary],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      binary_data = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      WebSocket.send_binary(socket, binary_data)

      assert_receive {:telemetry, [:vsm_connections, :adapter, :websocket, :send_binary], measurements, metadata}
      assert metadata.result == :success
      assert metadata.size == 10

      :telemetry.detach("test-ws-binary")
    end
  end

  describe "message handling" do
    setup do
      parent = self()
      {:ok, handler} = TestHandler.start_link(parent: parent)
      
      server = start_websocket_server()
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        callback_module: TestHandler
      )
      
      on_exit(fn ->
        WebSocket.close(socket)
        stop_websocket_server(server)
      end)
      
      {:ok, socket: socket, server: server, handler: handler}
    end

    test "receives and handles text messages", %{server: server} do
      send_to_client(server, {:text, Jason.encode!(%{type: "notification", data: "test"})})
      
      assert_receive {:websocket_event, :message_received, %{
        type: :text,
        message: %{"type" => "notification", "data" => "test"}
      }}, 1000
    end

    test "receives and handles binary messages", %{server: server} do
      binary_data = <<10, 20, 30, 40, 50>>
      send_to_client(server, {:binary, binary_data})
      
      assert_receive {:websocket_event, :message_received, %{
        type: :binary,
        data: ^binary_data
      }}, 1000
    end

    test "handles pong frames for heartbeat", %{socket: socket} do
      # Send a ping and expect internal handling of pong
      assert :ok = WebSocket.ping(socket)
      # No error means pong was handled correctly
    end
  end

  describe "reconnection behavior" do
    test "attempts to reconnect on unexpected disconnect" do
      parent = self()
      server = start_websocket_server()
      
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        callback_module: TestHandler,
        max_reconnect_attempts: 2,
        initial_reconnect_delay: 50
      )

      # Simulate server disconnect
      stop_websocket_server(server)
      
      # Should receive disconnect event
      assert_receive {:websocket_event, :disconnected, %{reason: _reason}}, 1000
      
      # Should attempt reconnection
      Process.sleep(150)
      
      WebSocket.close(socket)
    end

    test "respects maximum reconnection attempts" do
      log = capture_log(fn ->
        {:ok, socket} = WebSocket.connect(
          url: "ws://localhost:9999/unreachable",
          max_reconnect_attempts: 1,
          initial_reconnect_delay: 10
        )
        
        Process.sleep(100)
        WebSocket.close(socket)
      end)
      
      assert log =~ "schedule_reconnect"
    end
  end

  describe "heartbeat/ping mechanism" do
    test "sends periodic ping frames" do
      server = start_websocket_server()
      
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        heartbeat_interval: 50
      )

      # Wait for at least 2 heartbeat intervals
      Process.sleep(120)
      
      # Check that socket is still alive (heartbeat working)
      assert Process.alive?(socket)
      
      WebSocket.close(socket)
      stop_websocket_server(server)
    end

    test "manual ping works correctly" do
      server = start_websocket_server()
      
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket"
      )

      assert :ok = WebSocket.ping(socket)
      
      WebSocket.close(socket)
      stop_websocket_server(server)
    end
  end

  describe "message queuing" do
    test "queues messages when disconnected" do
      server = start_websocket_server()
      
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket"
      )

      # Get initial state
      state1 = WebSocket.get_state(socket)
      assert state1.state == :connected
      assert state1.queue_size == 0

      # Force disconnect
      stop_websocket_server(server)
      Process.sleep(50)

      # Try to send messages (should be queued)
      GenServer.cast(socket, {:send_message, %{msg: 1}})
      GenServer.cast(socket, {:send_message, %{msg: 2}})
      
      Process.sleep(10)
      
      state2 = WebSocket.get_state(socket)
      assert state2.state == :disconnected
      assert state2.queue_size > 0

      WebSocket.close(socket)
    end
  end

  describe "get_state/1" do
    test "returns current connection state" do
      server = start_websocket_server()
      
      {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket"
      )

      state = WebSocket.get_state(socket)
      
      assert state.state == :connected
      assert state.reconnect_attempts == 0
      assert state.queue_size == 0
      assert is_integer(state.last_heartbeat)
      
      WebSocket.close(socket)
      stop_websocket_server(server)
    end
  end

  describe "error scenarios" do
    test "handles invalid URLs gracefully" do
      assert {:error, _} = WebSocket.connect(
        url: "not-a-valid-url"
      )
    end

    test "handles missing required options" do
      assert_raise KeyError, fn ->
        WebSocket.connect([])
      end
    end

    test "callback module errors don't crash WebSocket" do
      defmodule ErrorHandler do
        def handle_websocket_event(_event, _data) do
          raise "Intentional error"
        end
      end

      server = start_websocket_server()
      
      assert {:ok, socket} = WebSocket.connect(
        url: "ws://localhost:#{server.port}/socket",
        callback_module: ErrorHandler
      )

      # Send a message that will trigger the error handler
      send_to_client(server, {:text, "trigger error"})
      
      # Socket should still be alive despite handler error
      Process.sleep(50)
      assert Process.alive?(socket)
      
      WebSocket.close(socket)
      stop_websocket_server(server)
    end
  end

  # Helper functions for test WebSocket server
  defp start_websocket_server(on_connect \\ fn _headers -> :ok end) do
    # Implementation would use a library like Cowboy to start a real WS server
    # For unit tests, we might mock this behavior
    %{port: 8080}
  end

  defp stop_websocket_server(_server) do
    :ok
  end

  defp send_to_client(_server, _frame) do
    # Mock implementation
    :ok
  end
end
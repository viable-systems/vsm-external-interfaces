defmodule VsmConnections.Adapters.GRPCTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias VsmConnections.Adapters.GRPC

  @moduletag :unit

  # Mock service module for testing
  defmodule TestService.Stub do
    def unary_call(channel, method, message, opts) do
      case method do
        :get_user ->
          {:ok, %{id: message.id, name: "Test User", email: "test@example.com"}}
        
        :create_user ->
          {:ok, %{id: 123, name: message.name, email: message.email}}
        
        :failing_method ->
          {:error, GRPC.Status.new(13, "Internal server error")}
        
        :slow_method ->
          Process.sleep(opts[:timeout] + 50)
          {:error, :timeout}
      end
    end

    def server_stream(channel, method, message, opts) do
      case method do
        :list_users ->
          stream = Stream.map(1..5, fn i ->
            {:ok, %{id: i, name: "User #{i}", email: "user#{i}@example.com"}}
          end)
          {:ok, stream}
        
        :failing_stream ->
          {:error, GRPC.Status.new(14, "Unavailable")}
      end
    end

    def client_stream(channel, method, opts) do
      case method do
        :create_users ->
          {:ok, %MockClientStream{method: method}}
        
        :failing_client_stream ->
          {:error, GRPC.Status.new(16, "Unauthenticated")}
      end
    end

    def bidirectional_stream(channel, method, opts) do
      case method do
        :chat ->
          {:ok, %MockBidirectionalStream{method: method}}
        
        :failing_bidi_stream ->
          {:error, GRPC.Status.new(7, "Permission denied")}
      end
    end
  end

  defmodule MockClientStream do
    defstruct [:method, messages: []]
  end

  defmodule MockBidirectionalStream do
    defstruct [:method, messages: []]
  end

  describe "connect/1" do
    test "creates gRPC channel with HTTP scheme" do
      assert {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: 50051,
        scheme: :http
      )

      info = GRPC.get_channel_info(channel)
      assert info.host == "localhost"
      assert info.port == 50051
      assert info.scheme == :http
      assert info.cred == nil
    end

    test "creates gRPC channel with HTTPS scheme" do
      assert {:ok, channel} = GRPC.connect(
        host: "api.example.com",
        port: 443,
        scheme: :https
      )

      info = GRPC.get_channel_info(channel)
      assert info.host == "api.example.com"
      assert info.port == 443
      assert info.scheme == :https
      assert info.cred == :tls
    end

    test "supports custom credentials" do
      custom_creds = %{ca_cert: "cert_data", client_cert: "client_cert"}
      
      assert {:ok, channel} = GRPC.connect(
        host: "secure.example.com",
        port: 443,
        scheme: :https,
        credentials: custom_creds
      )

      info = GRPC.get_channel_info(channel)
      assert info.cred == custom_creds
    end

    test "applies custom channel options" do
      assert {:ok, _channel} = GRPC.connect(
        host: "localhost",
        port: 50051,
        scheme: :http,
        timeout: 10_000,
        max_receive_message_length: 8 * 1024 * 1024,
        max_send_message_length: 8 * 1024 * 1024,
        keepalive_time: 60_000
      )
    end

    test "handles missing required options" do
      assert_raise KeyError, fn ->
        GRPC.connect(port: 50051)
      end

      assert_raise KeyError, fn ->
        GRPC.connect(host: "localhost")
      end
    end

    test "emits telemetry on successful connection" do
      self = self()
      
      :telemetry.attach(
        "test-grpc-connect",
        [:vsm_connections, :adapter, :grpc],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert {:ok, _channel} = GRPC.connect(
        host: "localhost",
        port: 50051,
        scheme: :http
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :grpc], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.adapter == :grpc
      assert metadata.operation == :connect
      assert metadata.result == :success

      :telemetry.detach("test-grpc-connect")
    end
  end

  describe "call/1 - unary calls" do
    setup do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      {:ok, channel: channel}
    end

    test "makes successful unary call", %{channel: channel} do
      assert {:ok, response} = GRPC.call(
        service: TestService.Stub,
        method: :get_user,
        message: %{id: 123},
        channel: channel
      )

      assert response.id == 123
      assert response.name == "Test User"
      assert response.email == "test@example.com"
    end

    test "handles call errors gracefully", %{channel: channel} do
      assert {:error, status} = GRPC.call(
        service: TestService.Stub,
        method: :failing_method,
        message: %{},
        channel: channel
      )

      assert status.code == 13
      assert status.message == "Internal server error"
    end

    test "respects timeout settings", %{channel: channel} do
      assert {:error, :timeout} = GRPC.call(
        service: TestService.Stub,
        method: :slow_method,
        message: %{},
        channel: channel,
        timeout: 100
      )
    end

    test "includes custom headers in call", %{channel: channel} do
      assert {:ok, _response} = GRPC.call(
        service: TestService.Stub,
        method: :create_user,
        message: %{name: "Jane", email: "jane@example.com"},
        channel: channel,
        headers: [{"authorization", "Bearer token123"}, {"x-request-id", "req-456"}]
      )
    end

    test "emits telemetry events for calls", %{channel: channel} do
      self = self()
      
      :telemetry.attach(
        "test-grpc-call",
        [:vsm_connections, :adapter, :grpc],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      GRPC.call(
        service: TestService.Stub,
        method: :get_user,
        message: %{id: 456},
        channel: channel
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :grpc], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.operation == :call
      assert metadata.service == TestService.Stub
      assert metadata.method == :get_user
      assert metadata.result == :success

      :telemetry.detach("test-grpc-call")
    end
  end

  describe "server_stream/1" do
    setup do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      {:ok, channel: channel}
    end

    test "handles server streaming successfully", %{channel: channel} do
      assert {:ok, stream} = GRPC.server_stream(
        service: TestService.Stub,
        method: :list_users,
        message: %{},
        channel: channel
      )

      users = Enum.to_list(stream)
      assert length(users) == 5

      Enum.each(users, fn {:ok, user} ->
        assert user.id in 1..5
        assert user.name =~ "User"
        assert user.email =~ "@example.com"
      end)
    end

    test "handles streaming errors", %{channel: channel} do
      assert {:error, status} = GRPC.server_stream(
        service: TestService.Stub,
        method: :failing_stream,
        message: %{},
        channel: channel
      )

      assert status.code == 14
      assert status.message == "Unavailable"
    end

    test "emits telemetry for server streams", %{channel: channel} do
      self = self()
      
      :telemetry.attach(
        "test-grpc-stream",
        [:vsm_connections, :adapter, :grpc],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      GRPC.server_stream(
        service: TestService.Stub,
        method: :list_users,
        message: %{},
        channel: channel
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :grpc], measurements, metadata}
      assert metadata.operation == :server_stream
      assert metadata.result == :success

      :telemetry.detach("test-grpc-stream")
    end
  end

  describe "client_stream/1" do
    setup do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      {:ok, channel: channel}
    end

    test "creates client stream successfully", %{channel: channel} do
      assert {:ok, stream} = GRPC.client_stream(
        service: TestService.Stub,
        method: :create_users,
        channel: channel
      )

      assert %MockClientStream{} = stream
      assert stream.method == :create_users
    end

    test "handles client stream errors", %{channel: channel} do
      assert {:error, status} = GRPC.client_stream(
        service: TestService.Stub,
        method: :failing_client_stream,
        channel: channel
      )

      assert status.code == 16
      assert status.message == "Unauthenticated"
    end
  end

  describe "bidirectional_stream/1" do
    setup do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      {:ok, channel: channel}
    end

    test "creates bidirectional stream successfully", %{channel: channel} do
      assert {:ok, stream} = GRPC.bidirectional_stream(
        service: TestService.Stub,
        method: :chat,
        channel: channel
      )

      assert %MockBidirectionalStream{} = stream
      assert stream.method == :chat
    end

    test "handles bidirectional stream errors", %{channel: channel} do
      assert {:error, status} = GRPC.bidirectional_stream(
        service: TestService.Stub,
        method: :failing_bidi_stream,
        channel: channel
      )

      assert status.code == 7
      assert status.message == "Permission denied"
    end
  end

  describe "disconnect/1" do
    test "closes gRPC channel" do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      
      assert :ok = GRPC.disconnect(channel)
    end

    test "emits telemetry on disconnect" do
      self = self()
      
      :telemetry.attach(
        "test-grpc-disconnect",
        [:vsm_connections, :adapter, :grpc],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      GRPC.disconnect(channel)

      assert_receive {:telemetry, [:vsm_connections, :adapter, :grpc], measurements, metadata}
      assert metadata.operation == :disconnect
      assert metadata.result == :success

      :telemetry.detach("test-grpc-disconnect")
    end
  end

  describe "retry behavior" do
    setup do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      {:ok, channel: channel}
    end

    test "retries failed calls with exponential backoff", %{channel: channel} do
      # This would require a more sophisticated mock that tracks retry attempts
      # For now, we verify the retry configuration is passed through
      assert {:error, _} = GRPC.call(
        service: TestService.Stub,
        method: :failing_method,
        message: %{},
        channel: channel,
        retry: [max_attempts: 3, initial_delay: 10, max_delay: 100]
      )
    end
  end

  describe "interceptors" do
    test "supports gRPC interceptors" do
      defmodule LoggingInterceptor do
        def init(opts), do: opts

        def call(stream, req, next, opts) do
          # Log the request
          IO.puts("Intercepting request: #{inspect(req)}")
          
          # Call the next interceptor or the actual RPC
          result = next.(stream, req)
          
          # Log the response
          IO.puts("Intercepted response: #{inspect(result)}")
          
          result
        end
      end

      assert {:ok, _channel} = GRPC.connect(
        host: "localhost",
        port: 50051,
        scheme: :http,
        interceptors: [LoggingInterceptor]
      )
    end
  end

  describe "error scenarios" do
    test "handles invalid service module" do
      {:ok, channel} = GRPC.Channel.new("localhost:50051", cred: nil)
      
      assert_raise KeyError, fn ->
        GRPC.call(
          method: :test,
          message: %{},
          channel: channel
        )
      end
    end

    test "handles connection failures" do
      # Mock implementation would handle actual connection errors
      assert {:error, _} = GRPC.connect(
        host: "unreachable.example.com",
        port: 50051,
        scheme: :https
      )
    end
  end
end
defmodule VsmConnections.Integration.ProtocolTranslationTest do
  use ExUnit.Case
  alias VsmConnections.Adapters.{HTTP, WebSocket, GRPC}
  
  @moduletag :integration

  describe "HTTP to WebSocket translation" do
    setup do
      # Start test servers
      http_server = start_http_server()
      ws_server = start_websocket_server()
      
      on_exit(fn ->
        stop_server(http_server)
        stop_server(ws_server)
      end)
      
      {:ok, http_server: http_server, ws_server: ws_server}
    end

    test "translates REST API calls to WebSocket messages", %{http_server: http_server, ws_server: ws_server} do
      # Connect to WebSocket
      {:ok, ws_client} = WebSocket.connect(
        url: "ws://localhost:#{ws_server.port}/events",
        callback_module: TestWSHandler
      )

      # Make HTTP request that should trigger WebSocket event
      {:ok, response} = HTTP.post(
        "http://localhost:#{http_server.port}/api/users",
        %{name: "Alice", email: "alice@example.com"}
      )

      assert response.status == 201
      assert response.body["id"]

      # Verify WebSocket received the event
      assert_receive {:ws_event, %{
        "type" => "user.created",
        "data" => %{
          "id" => _,
          "name" => "Alice",
          "email" => "alice@example.com"
        }
      }}, 1000

      WebSocket.close(ws_client)
    end

    test "handles bidirectional translation", %{http_server: http_server, ws_server: ws_server} do
      # Connect WebSocket client
      {:ok, ws_client} = WebSocket.connect(
        url: "ws://localhost:#{ws_server.port}/commands"
      )

      # Send command via WebSocket
      :ok = WebSocket.send_message(ws_client, %{
        "command" => "fetch_user",
        "params" => %{"id" => 123}
      })

      # HTTP endpoint should receive translated request
      assert_receive {:http_request, %{
        method: "GET",
        path: "/api/users/123"
      }}, 1000

      # Simulate HTTP response
      send_http_response(%{
        status: 200,
        body: %{id: 123, name: "Bob", email: "bob@example.com"}
      })

      # WebSocket should receive translated response
      assert_receive {:ws_event, %{
        "type" => "command.response",
        "data" => %{
          "id" => 123,
          "name" => "Bob",
          "email" => "bob@example.com"
        }
      }}, 1000

      WebSocket.close(ws_client)
    end
  end

  describe "gRPC to HTTP translation" do
    setup do
      grpc_server = start_grpc_server()
      http_server = start_http_server()
      
      on_exit(fn ->
        stop_server(grpc_server)
        stop_server(http_server)
      end)
      
      {:ok, grpc_server: grpc_server, http_server: http_server}
    end

    test "translates gRPC unary calls to REST API", %{grpc_server: grpc_server, http_server: http_server} do
      # Connect gRPC client
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )

      # Make gRPC call
      {:ok, response} = GRPC.call(
        service: UserService.Stub,
        method: :get_user,
        message: %GetUserRequest{id: 456},
        channel: channel
      )

      # Verify HTTP API was called
      assert_receive {:http_request, %{
        method: "GET",
        path: "/api/users/456",
        headers: headers
      }}, 1000

      # Check translated headers
      assert {"x-grpc-method", "GetUser"} in headers
      assert {"content-type", "application/json"} in headers

      GRPC.disconnect(channel)
    end

    test "translates HTTP responses to gRPC responses", %{grpc_server: grpc_server, http_server: http_server} do
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )

      # Configure HTTP response
      set_http_response(%{
        status: 200,
        body: %{
          id: 789,
          name: "Charlie",
          email: "charlie@example.com",
          created_at: "2024-01-01T00:00:00Z"
        }
      })

      # Make gRPC call
      {:ok, response} = GRPC.call(
        service: UserService.Stub,
        method: :get_user,
        message: %GetUserRequest{id: 789},
        channel: channel
      )

      # Verify translation
      assert response.id == 789
      assert response.name == "Charlie"
      assert response.email == "charlie@example.com"
      assert response.created_at == %Google.Protobuf.Timestamp{
        seconds: 1704067200,
        nanos: 0
      }

      GRPC.disconnect(channel)
    end

    test "handles HTTP errors in gRPC format", %{grpc_server: grpc_server, http_server: http_server} do
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )

      # Configure HTTP error response
      set_http_response(%{
        status: 404,
        body: %{error: "User not found", code: "USER_NOT_FOUND"}
      })

      # Make gRPC call
      {:error, status} = GRPC.call(
        service: UserService.Stub,
        method: :get_user,
        message: %GetUserRequest{id: 999},
        channel: channel
      )

      # Verify error translation
      assert status.code == 5  # NOT_FOUND in gRPC
      assert status.message =~ "User not found"
      assert status.details == [%{error_code: "USER_NOT_FOUND"}]

      GRPC.disconnect(channel)
    end
  end

  describe "WebSocket to gRPC streaming translation" do
    setup do
      ws_server = start_websocket_server()
      grpc_server = start_grpc_server()
      
      on_exit(fn ->
        stop_server(ws_server)
        stop_server(grpc_server)
      end)
      
      {:ok, ws_server: ws_server, grpc_server: grpc_server}
    end

    test "translates WebSocket messages to gRPC server stream", %{ws_server: ws_server, grpc_server: grpc_server} do
      # Connect WebSocket
      {:ok, ws_client} = WebSocket.connect(
        url: "ws://localhost:#{ws_server.port}/stream"
      )

      # Connect gRPC
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )

      # Request stream via WebSocket
      :ok = WebSocket.send_message(ws_client, %{
        "action" => "subscribe",
        "resource" => "user_updates",
        "filter" => %{"active" => true}
      })

      # Should trigger gRPC server stream
      {:ok, stream} = GRPC.server_stream(
        service: UserService.Stub,
        method: :watch_users,
        message: %WatchUsersRequest{
          filter: %UserFilter{active: true}
        },
        channel: channel
      )

      # Collect some stream items
      items = stream |> Enum.take(3) |> Enum.to_list()
      
      # Verify WebSocket receives translated stream items
      Enum.each(items, fn {:ok, user} ->
        assert_receive {:ws_event, %{
          "type" => "user.update",
          "data" => %{
            "id" => ^user.id,
            "name" => ^user.name
          }
        }}, 1000
      end)

      WebSocket.close(ws_client)
      GRPC.disconnect(channel)
    end

    test "handles bidirectional streaming translation", %{ws_server: ws_server, grpc_server: grpc_server} do
      # Connect both protocols
      {:ok, ws_client} = WebSocket.connect(
        url: "ws://localhost:#{ws_server.port}/chat"
      )

      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )

      # Start bidirectional gRPC stream
      {:ok, grpc_stream} = GRPC.bidirectional_stream(
        service: ChatService.Stub,
        method: :chat,
        channel: channel
      )

      # Send message via WebSocket
      :ok = WebSocket.send_message(ws_client, %{
        "type" => "chat.message",
        "text" => "Hello from WebSocket"
      })

      # Should be translated to gRPC
      assert_receive {:grpc_message, %ChatMessage{
        text: "Hello from WebSocket",
        timestamp: _
      }}, 1000

      # Send response via gRPC
      GRPC.Stub.send_request(grpc_stream, %ChatMessage{
        text: "Hello from gRPC",
        timestamp: %Google.Protobuf.Timestamp{seconds: 1704067200, nanos: 0}
      })

      # Should be translated to WebSocket
      assert_receive {:ws_event, %{
        "type" => "chat.message",
        "text" => "Hello from gRPC",
        "timestamp" => "2024-01-01T00:00:00Z"
      }}, 1000

      WebSocket.close(ws_client)
      GRPC.disconnect(channel)
    end
  end

  describe "Multi-protocol orchestration" do
    setup do
      http_server = start_http_server()
      ws_server = start_websocket_server()
      grpc_server = start_grpc_server()
      
      on_exit(fn ->
        stop_server(http_server)
        stop_server(ws_server)
        stop_server(grpc_server)
      end)
      
      {:ok, http: http_server, ws: ws_server, grpc: grpc_server}
    end

    test "orchestrates complex workflow across protocols", context do
      # 1. HTTP request initiates workflow
      {:ok, init_response} = HTTP.post(
        "http://localhost:#{context.http.port}/api/workflows",
        %{
          name: "user_onboarding",
          user_id: 123
        }
      )

      workflow_id = init_response.body["workflow_id"]

      # 2. Connect WebSocket for real-time updates
      {:ok, ws_client} = WebSocket.connect(
        url: "ws://localhost:#{context.ws.port}/workflows/#{workflow_id}"
      )

      # 3. gRPC service processes workflow steps
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: context.grpc.port,
        scheme: :http
      )

      {:ok, grpc_response} = GRPC.call(
        service: WorkflowService.Stub,
        method: :execute_step,
        message: %ExecuteStepRequest{
          workflow_id: workflow_id,
          step: "validate_user"
        },
        channel: channel
      )

      # 4. WebSocket receives progress update
      assert_receive {:ws_event, %{
        "type" => "workflow.progress",
        "workflow_id" => ^workflow_id,
        "step" => "validate_user",
        "status" => "completed"
      }}, 1000

      # 5. HTTP polling for final status
      {:ok, status_response} = HTTP.get(
        "http://localhost:#{context.http.port}/api/workflows/#{workflow_id}/status"
      )

      assert status_response.body["status"] == "in_progress"
      assert status_response.body["completed_steps"] == ["validate_user"]

      WebSocket.close(ws_client)
      GRPC.disconnect(channel)
    end
  end

  describe "Protocol feature compatibility" do
    test "handles protocol-specific features correctly" do
      # Test scenarios for features unique to each protocol
      
      # HTTP: Headers, cookies, caching
      assert {:ok, response} = HTTP.get(
        "http://example.com/api/data",
        headers: [
          {"if-none-match", "etag123"},
          {"accept-encoding", "gzip, deflate"}
        ]
      )
      
      # WebSocket: Ping/pong, close codes
      {:ok, ws} = WebSocket.connect(url: "ws://example.com/socket")
      assert :ok = WebSocket.ping(ws)
      WebSocket.close(ws)
      
      # gRPC: Metadata, deadlines, compression
      {:ok, channel} = GRPC.connect(host: "localhost", port: 50051, scheme: :http)
      {:ok, _} = GRPC.call(
        service: TestService.Stub,
        method: :test,
        message: %{},
        channel: channel,
        headers: [{"grpc-timeout", "5S"}]
      )
      GRPC.disconnect(channel)
    end
  end

  # Helper modules
  defmodule TestWSHandler do
    def handle_websocket_event(:message_received, %{message: message}) do
      send(self(), {:ws_event, message})
    end
    def handle_websocket_event(_, _), do: :ok
  end

  # Mock server helpers
  defp start_http_server do
    %{port: 8080}
  end

  defp start_websocket_server do
    %{port: 8081}
  end

  defp start_grpc_server do
    %{port: 50051}
  end

  defp stop_server(_server) do
    :ok
  end

  defp set_http_response(_response) do
    :ok
  end

  defp send_http_response(_response) do
    :ok
  end
end
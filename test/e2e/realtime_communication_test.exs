defmodule VsmConnections.E2E.RealtimeCommunicationTest do
  use ExUnit.Case
  alias VsmConnections.Adapters.{HTTP, WebSocket, GRPC}
  import VsmConnections.TestHelpers

  @moduletag :e2e
  @moduletag timeout: 300_000  # 5 minutes for comprehensive tests

  describe "Real-time chat application scenario" do
    setup do
      # Setup test infrastructure
      chat_server = setup_chat_infrastructure()
      
      on_exit(fn ->
        teardown_chat_infrastructure(chat_server)
      end)
      
      {:ok, server: chat_server}
    end

    test "multi-user chat with presence tracking", %{server: server} do
      # Create multiple users
      users = for i <- 1..5 do
        {:ok, user_id} = create_user(server, "User#{i}")
        user_id
      end

      # Connect each user via WebSocket
      connections = Enum.map(users, fn user_id ->
        {:ok, ws} = WebSocket.connect(
          url: "#{server.ws_url}/chat/#{user_id}",
          callback_module: ChatHandler
        )
        {user_id, ws}
      end)

      # Verify all users receive presence updates
      Enum.each(connections, fn {user_id, _ws} ->
        assert_receive {:presence_update, %{
          "type" => "user_joined",
          "user_id" => ^user_id,
          "online_users" => online_list
        }}, 2000
        
        assert length(online_list) == 5
      end)

      # User 1 sends a message
      {user1_id, ws1} = List.first(connections)
      message_id = send_chat_message(ws1, "Hello everyone!")

      # All other users should receive it
      Enum.each(tl(connections), fn {_user_id, _ws} ->
        assert_receive {:chat_message, %{
          "id" => ^message_id,
          "from" => ^user1_id,
          "text" => "Hello everyone!",
          "timestamp" => _
        }}, 1000
      end)

      # Test typing indicators
      WebSocket.send_message(ws1, %{
        "type" => "typing_start",
        "channel" => "general"
      })

      # Others should see typing indicator
      Enum.each(tl(connections), fn {_user_id, _ws} ->
        assert_receive {:typing_indicator, %{
          "user_id" => ^user1_id,
          "typing" => true
        }}, 500
      end)

      # Disconnect one user
      {disconnected_user, ws_to_close} = List.last(connections)
      WebSocket.close(ws_to_close)

      # Others should receive presence update
      Enum.each(Enum.take(connections, 4), fn {_user_id, _ws} ->
        assert_receive {:presence_update, %{
          "type" => "user_left",
          "user_id" => ^disconnected_user
        }}, 2000
      end)

      # Clean up remaining connections
      Enum.each(Enum.take(connections, 4), fn {_user_id, ws} ->
        WebSocket.close(ws)
      end)
    end

    test "message history and synchronization", %{server: server} do
      # User 1 connects and sends messages
      {:ok, user1} = create_user(server, "User1")
      {:ok, ws1} = WebSocket.connect(url: "#{server.ws_url}/chat/#{user1}")

      # Send several messages
      message_ids = for i <- 1..10 do
        send_chat_message(ws1, "Message #{i}")
      end

      # User 2 connects later
      {:ok, user2} = create_user(server, "User2")
      
      # Fetch history via HTTP before connecting
      {:ok, history} = HTTP.get("#{server.http_url}/api/chat/history?limit=5")
      assert length(history.body["messages"]) == 5
      assert Enum.all?(history.body["messages"], & &1["id"] in message_ids)

      # Connect via WebSocket with last_seen parameter
      last_message_id = List.last(message_ids)
      {:ok, ws2} = WebSocket.connect(
        url: "#{server.ws_url}/chat/#{user2}?last_seen=#{last_message_id}"
      )

      # Should receive catch-up messages
      assert_receive {:sync_messages, messages}, 2000
      assert length(messages) == 0  # Already saw all messages

      # Send new message
      new_msg_id = send_chat_message(ws1, "New message after sync")

      # User 2 should receive it in real-time
      assert_receive {:chat_message, %{
        "id" => ^new_msg_id,
        "text" => "New message after sync"
      }}, 1000

      WebSocket.close(ws1)
      WebSocket.close(ws2)
    end

    test "file upload with progress streaming", %{server: server} do
      {:ok, user} = create_user(server, "FileUploader")
      {:ok, ws} = WebSocket.connect(url: "#{server.ws_url}/chat/#{user}")

      # Start file upload via HTTP with progress tracking
      file_size = 10 * 1024 * 1024  # 10MB
      file_data = :crypto.strong_rand_bytes(file_size)
      
      upload_task = Task.async(fn ->
        HTTP.post(
          "#{server.http_url}/api/files/upload",
          file_data,
          headers: [
            {"content-type", "application/octet-stream"},
            {"x-file-name", "test-file.bin"},
            {"x-user-id", user}
          ]
        )
      end)

      # Receive progress updates via WebSocket
      progress_updates = collect_progress_updates(ws, 30_000)
      
      # Verify progress updates
      assert length(progress_updates) > 5
      assert List.first(progress_updates)["percent"] < List.last(progress_updates)["percent"]
      assert List.last(progress_updates)["percent"] == 100

      # Wait for upload completion
      {:ok, upload_result} = Task.await(upload_task, 35_000)
      assert upload_result.status == 201
      file_id = upload_result.body["file_id"]

      # Verify file metadata via gRPC
      {:ok, channel} = GRPC.connect(
        host: server.grpc_host,
        port: server.grpc_port,
        scheme: :http
      )

      {:ok, file_info} = GRPC.call(
        service: FileService.Stub,
        method: :get_file_info,
        message: %GetFileInfoRequest{file_id: file_id},
        channel: channel
      )

      assert file_info.size == file_size
      assert file_info.name == "test-file.bin"
      assert file_info.uploader_id == user

      GRPC.disconnect(channel)
      WebSocket.close(ws)
    end
  end

  describe "Live streaming scenario" do
    setup do
      stream_server = setup_streaming_infrastructure()
      
      on_exit(fn ->
        teardown_streaming_infrastructure(stream_server)
      end)
      
      {:ok, server: stream_server}
    end

    test "live video stream with multiple viewers", %{server: server} do
      # Broadcaster starts stream via gRPC
      {:ok, broadcast_channel} = GRPC.connect(
        host: server.grpc_host,
        port: server.grpc_port,
        scheme: :http
      )

      {:ok, stream_id} = start_broadcast(broadcast_channel, %{
        title: "Test Stream",
        quality: "1080p",
        bitrate: 5000
      })

      # Multiple viewers connect via WebSocket
      viewers = for i <- 1..10 do
        {:ok, ws} = WebSocket.connect(
          url: "#{server.ws_url}/stream/#{stream_id}/view"
        )
        {i, ws}
      end

      # Broadcaster sends video chunks
      video_chunks = for i <- 1..100 do
        chunk_data = generate_video_chunk(i, 1024 * 50)  # 50KB chunks
        
        {:ok, _} = GRPC.call(
          service: StreamService.Stub,
          method: :send_chunk,
          message: %VideoChunk{
            stream_id: stream_id,
            sequence: i,
            data: chunk_data,
            timestamp: System.system_time(:millisecond)
          },
          channel: broadcast_channel
        )
        
        Process.sleep(100)  # Simulate 10fps
        chunk_data
      end

      # Verify viewers receive chunks
      Enum.each(viewers, fn {viewer_id, ws} ->
        received_chunks = collect_stream_chunks(ws, 15_000)
        
        # Should receive most chunks (allow for some packet loss)
        assert length(received_chunks) > 90
        
        # Verify chunk integrity
        assert Enum.all?(received_chunks, fn chunk ->
          chunk["stream_id"] == stream_id and
          chunk["data"] != nil
        end)
      end)

      # Get stream statistics via HTTP
      {:ok, stats} = HTTP.get("#{server.http_url}/api/streams/#{stream_id}/stats")
      
      assert stats.body["viewer_count"] == 10
      assert stats.body["chunks_sent"] == 100
      assert stats.body["status"] == "live"

      # Stop broadcast
      stop_broadcast(broadcast_channel, stream_id)

      # Viewers should receive stream end notification
      Enum.each(viewers, fn {_viewer_id, ws} ->
        assert_receive {:stream_event, %{
          "type" => "stream_ended",
          "stream_id" => ^stream_id
        }}, 2000
        
        WebSocket.close(ws)
      end)

      GRPC.disconnect(broadcast_channel)
    end

    test "adaptive bitrate streaming", %{server: server} do
      {:ok, broadcast_channel} = GRPC.connect(
        host: server.grpc_host,
        port: server.grpc_port,
        scheme: :http
      )

      # Start multi-quality stream
      {:ok, stream_id} = start_adaptive_stream(broadcast_channel, %{
        qualities: ["360p", "720p", "1080p"],
        base_bitrate: 1000
      })

      # Viewers with different bandwidth
      viewers = [
        {:ok, ws_low} = WebSocket.connect(
          url: "#{server.ws_url}/stream/#{stream_id}/view",
          headers: [{"x-bandwidth", "low"}]
        ),
        {:ok, ws_medium} = WebSocket.connect(
          url: "#{server.ws_url}/stream/#{stream_id}/view",
          headers: [{"x-bandwidth", "medium"}]
        ),
        {:ok, ws_high} = WebSocket.connect(
          url: "#{server.ws_url}/stream/#{stream_id}/view",
          headers: [{"x-bandwidth", "high"}]
        )
      ]

      # Send chunks at different qualities
      for i <- 1..50 do
        for quality <- ["360p", "720p", "1080p"] do
          chunk_size = case quality do
            "360p" -> 10 * 1024
            "720p" -> 30 * 1024
            "1080p" -> 50 * 1024
          end

          GRPC.call(
            service: StreamService.Stub,
            method: :send_adaptive_chunk,
            message: %AdaptiveVideoChunk{
              stream_id: stream_id,
              sequence: i,
              quality: quality,
              data: :crypto.strong_rand_bytes(chunk_size)
            },
            channel: broadcast_channel
          )
        end
        
        Process.sleep(100)
      end

      # Verify each viewer receives appropriate quality
      [ws_low, ws_medium, ws_high] = viewers
      
      low_chunks = collect_stream_chunks(ws_low, 10_000)
      assert Enum.all?(low_chunks, & &1["quality"] == "360p")
      
      medium_chunks = collect_stream_chunks(ws_medium, 10_000)
      assert Enum.all?(medium_chunks, & &1["quality"] == "720p")
      
      high_chunks = collect_stream_chunks(ws_high, 10_000)
      assert Enum.all?(high_chunks, & &1["quality"] == "1080p")

      # Clean up
      Enum.each(viewers, &WebSocket.close/1)
      GRPC.disconnect(broadcast_channel)
    end
  end

  describe "IoT sensor data streaming" do
    setup do
      iot_server = setup_iot_infrastructure()
      
      on_exit(fn ->
        teardown_iot_infrastructure(iot_server)
      end)
      
      {:ok, server: iot_server}
    end

    test "high-frequency sensor data with aggregation", %{server: server} do
      # Register sensors via HTTP
      sensor_ids = for i <- 1..20 do
        {:ok, resp} = HTTP.post(
          "#{server.http_url}/api/sensors/register",
          %{
            name: "Sensor-#{i}",
            type: "temperature",
            location: "Zone-#{rem(i, 5) + 1}"
          }
        )
        resp.body["sensor_id"]
      end

      # Connect sensors via WebSocket
      sensor_connections = Enum.map(sensor_ids, fn sensor_id ->
        {:ok, ws} = WebSocket.connect(
          url: "#{server.ws_url}/sensors/#{sensor_id}/data"
        )
        {sensor_id, ws}
      end)

      # Dashboard connects via gRPC for aggregated data
      {:ok, dashboard_channel} = GRPC.connect(
        host: server.grpc_host,
        port: server.grpc_port,
        scheme: :http
      )

      {:ok, stream} = GRPC.server_stream(
        service: SensorService.Stub,
        method: :subscribe_aggregated,
        message: %AggregationRequest{
          interval_ms: 1000,
          aggregation_type: "average",
          group_by: "location"
        },
        channel: dashboard_channel
      )

      # Start sending sensor data
      sensor_task = Task.async(fn ->
        for _ <- 1..100 do
          Enum.each(sensor_connections, fn {sensor_id, ws} ->
            temperature = 20.0 + :rand.uniform() * 10.0
            
            WebSocket.send_message(ws, %{
              "sensor_id" => sensor_id,
              "value" => temperature,
              "timestamp" => System.system_time(:millisecond),
              "unit" => "celsius"
            })
          end)
          
          Process.sleep(50)  # 20Hz per sensor
        end
      end)

      # Collect aggregated data
      aggregated_data = stream
        |> Stream.take(10)
        |> Enum.to_list()

      # Verify aggregation
      assert length(aggregated_data) == 10
      
      Enum.each(aggregated_data, fn {:ok, aggregate} ->
        # Should have data for each zone
        assert map_size(aggregate.zone_averages) == 5
        
        # Each zone should have reasonable temperature
        Enum.each(aggregate.zone_averages, fn {_zone, avg_temp} ->
          assert avg_temp >= 20.0 and avg_temp <= 30.0
        end)
      end)

      # Wait for sensor task
      Task.await(sensor_task)

      # Query historical data via HTTP
      {:ok, history} = HTTP.get(
        "#{server.http_url}/api/sensors/history",
        params: %{
          start_time: System.system_time(:millisecond) - 10_000,
          end_time: System.system_time(:millisecond),
          resolution: "1s"
        }
      )

      assert length(history.body["data_points"]) > 0

      # Clean up
      Enum.each(sensor_connections, fn {_id, ws} ->
        WebSocket.close(ws)
      end)
      GRPC.disconnect(dashboard_channel)
    end
  end

  # Helper modules and functions
  defmodule ChatHandler do
    def handle_websocket_event(:message_received, %{message: message}) do
      case message["type"] do
        "presence_update" ->
          send(self(), {:presence_update, message})
        
        "chat_message" ->
          send(self(), {:chat_message, message})
        
        "typing_indicator" ->
          send(self(), {:typing_indicator, message})
        
        "sync_messages" ->
          send(self(), {:sync_messages, message["messages"]})
        
        "file_progress" ->
          send(self(), {:file_progress, message})
        
        "stream_chunk" ->
          send(self(), {:stream_chunk, message})
        
        "stream_event" ->
          send(self(), {:stream_event, message})
        
        _ ->
          :ok
      end
    end

    def handle_websocket_event(_, _), do: :ok
  end

  defp setup_chat_infrastructure do
    %{
      http_url: "http://localhost:8080",
      ws_url: "ws://localhost:8081",
      grpc_host: "localhost",
      grpc_port: 50051
    }
  end

  defp teardown_chat_infrastructure(_server) do
    :ok
  end

  defp setup_streaming_infrastructure do
    %{
      http_url: "http://localhost:8082",
      ws_url: "ws://localhost:8083",
      grpc_host: "localhost",
      grpc_port: 50052
    }
  end

  defp teardown_streaming_infrastructure(_server) do
    :ok
  end

  defp setup_iot_infrastructure do
    %{
      http_url: "http://localhost:8084",
      ws_url: "ws://localhost:8085",
      grpc_host: "localhost",
      grpc_port: 50053
    }
  end

  defp teardown_iot_infrastructure(_server) do
    :ok
  end

  defp create_user(server, username) do
    {:ok, resp} = HTTP.post(
      "#{server.http_url}/api/users",
      %{username: username}
    )
    {:ok, resp.body["user_id"]}
  end

  defp send_chat_message(ws, text) do
    message_id = "msg_#{System.unique_integer([:positive])}"
    
    WebSocket.send_message(ws, %{
      "type" => "send_message",
      "id" => message_id,
      "text" => text,
      "channel" => "general"
    })
    
    message_id
  end

  defp collect_progress_updates(ws, timeout) do
    collect_messages_until(ws, :file_progress, timeout)
  end

  defp collect_stream_chunks(ws, timeout) do
    collect_messages_until(ws, :stream_chunk, timeout)
  end

  defp collect_messages_until(ws, message_type, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_messages_until(ws, message_type, deadline, [])
  end

  defp collect_messages_until(_ws, _type, deadline, acc) when deadline <= System.monotonic_time(:millisecond) do
    Enum.reverse(acc)
  end

  defp collect_messages_until(ws, type, deadline, acc) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))
    
    receive do
      {^type, message} ->
        collect_messages_until(ws, type, deadline, [message | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  defp start_broadcast(channel, config) do
    {:ok, resp} = GRPC.call(
      service: StreamService.Stub,
      method: :start_broadcast,
      message: %StartBroadcastRequest{
        title: config.title,
        quality: config.quality,
        bitrate: config.bitrate
      },
      channel: channel
    )
    
    {:ok, resp.stream_id}
  end

  defp stop_broadcast(channel, stream_id) do
    GRPC.call(
      service: StreamService.Stub,
      method: :stop_broadcast,
      message: %StopBroadcastRequest{stream_id: stream_id},
      channel: channel
    )
  end

  defp start_adaptive_stream(channel, config) do
    {:ok, resp} = GRPC.call(
      service: StreamService.Stub,
      method: :start_adaptive_stream,
      message: %StartAdaptiveStreamRequest{
        qualities: config.qualities,
        base_bitrate: config.base_bitrate
      },
      channel: channel
    )
    
    {:ok, resp.stream_id}
  end

  defp generate_video_chunk(sequence, size) do
    # Simulate video chunk with header
    header = <<
      sequence::32,
      System.system_time(:millisecond)::64,
      size::32
    >>
    
    header <> :crypto.strong_rand_bytes(size - byte_size(header))
  end
end
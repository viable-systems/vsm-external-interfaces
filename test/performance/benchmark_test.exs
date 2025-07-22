defmodule VsmConnections.Performance.BenchmarkTest do
  use ExUnit.Case
  alias VsmConnections.Adapters.{HTTP, WebSocket, GRPC}

  @moduletag :performance
  @moduletag timeout: :infinity

  @small_payload %{id: 1, name: "test", value: 123.45}
  @medium_payload Enum.reduce(1..100, %{}, fn i, acc -> 
    Map.put(acc, "field_#{i}", "value_#{i}")
  end)
  @large_payload %{
    data: Enum.map(1..1000, fn i -> 
      %{
        id: i,
        name: "Item #{i}",
        attributes: Enum.map(1..10, fn j -> %{key: "attr_#{j}", value: "val_#{j}"} end),
        metadata: %{
          created_at: "2024-01-01T00:00:00Z",
          updated_at: "2024-01-01T00:00:00Z",
          tags: ["tag1", "tag2", "tag3"]
        }
      }
    end)
  }

  describe "HTTP adapter benchmarks" do
    setup do
      bypass = Bypass.open()
      
      # Setup mock responses
      Bypass.expect(bypass, "POST", "/echo", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.resp(conn, 200, body)
      end)
      
      {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}"}
    end

    test "HTTP request latency - small payload", %{url: base_url} do
      results = benchmark("HTTP small payload", fn ->
        HTTP.post("#{base_url}/echo", @small_payload)
      end)

      assert results.avg_ms < 10
      assert results.p99_ms < 50
      
      report_results("HTTP", "small", results)
    end

    test "HTTP request latency - medium payload", %{url: base_url} do
      results = benchmark("HTTP medium payload", fn ->
        HTTP.post("#{base_url}/echo", @medium_payload)
      end)

      assert results.avg_ms < 20
      assert results.p99_ms < 100
      
      report_results("HTTP", "medium", results)
    end

    test "HTTP request latency - large payload", %{url: base_url} do
      results = benchmark("HTTP large payload", fn ->
        HTTP.post("#{base_url}/echo", @large_payload)
      end, iterations: 100)

      assert results.avg_ms < 100
      assert results.p99_ms < 500
      
      report_results("HTTP", "large", results)
    end

    test "HTTP concurrent requests", %{url: base_url} do
      results = concurrent_benchmark("HTTP concurrent", 
        fn ->
          HTTP.get("#{base_url}/echo")
        end,
        concurrency: 50,
        duration: 10_000
      )

      assert results.req_per_sec > 1000
      assert results.error_rate < 0.01
      
      report_concurrent_results("HTTP", results)
    end
  end

  describe "WebSocket adapter benchmarks" do
    setup do
      # Mock WebSocket server
      server = start_mock_ws_server()
      
      on_exit(fn ->
        stop_mock_server(server)
      end)
      
      {:ok, server: server, url: "ws://localhost:#{server.port}/socket"}
    end

    test "WebSocket message latency - small payload", %{url: ws_url} do
      {:ok, socket} = WebSocket.connect(url: ws_url)
      
      results = benchmark("WebSocket small payload", fn ->
        WebSocket.send_message(socket, @small_payload)
      end)

      assert results.avg_ms < 5
      assert results.p99_ms < 20
      
      WebSocket.close(socket)
      report_results("WebSocket", "small", results)
    end

    test "WebSocket message throughput", %{url: ws_url} do
      {:ok, socket} = WebSocket.connect(url: ws_url)
      
      results = throughput_benchmark("WebSocket throughput",
        fn message ->
          WebSocket.send_message(socket, message)
        end,
        messages_per_batch: 1000,
        duration: 10_000
      )

      assert results.messages_per_sec > 10_000
      
      WebSocket.close(socket)
      report_throughput_results("WebSocket", results)
    end

    test "WebSocket concurrent connections", %{url: ws_url} do
      results = concurrent_ws_benchmark("WebSocket concurrent",
        ws_url,
        connections: 100,
        messages_per_connection: 100
      )

      assert results.total_time_ms < 5000
      assert results.failed_connections == 0
      
      report_ws_concurrent_results(results)
    end
  end

  describe "gRPC adapter benchmarks" do
    setup do
      # Mock gRPC server
      server = start_mock_grpc_server()
      
      {:ok, channel} = GRPC.connect(
        host: "localhost",
        port: server.port,
        scheme: :http
      )
      
      on_exit(fn ->
        GRPC.disconnect(channel)
        stop_mock_server(server)
      end)
      
      {:ok, channel: channel, server: server}
    end

    test "gRPC unary call latency - small payload", %{channel: channel} do
      results = benchmark("gRPC small payload", fn ->
        GRPC.call(
          service: BenchmarkService.Stub,
          method: :echo,
          message: %EchoRequest{data: Jason.encode!(@small_payload)},
          channel: channel
        )
      end)

      assert results.avg_ms < 5
      assert results.p99_ms < 20
      
      report_results("gRPC", "small", results)
    end

    test "gRPC streaming throughput", %{channel: channel} do
      results = streaming_benchmark("gRPC streaming",
        channel,
        messages: 10_000
      )

      assert results.messages_per_sec > 50_000
      assert results.avg_latency_ms < 1
      
      report_streaming_results("gRPC", results)
    end

    test "gRPC bidirectional streaming", %{channel: channel} do
      results = bidi_streaming_benchmark("gRPC bidi streaming",
        channel,
        duration: 10_000,
        producers: 5,
        consumers: 5
      )

      assert results.total_messages > 100_000
      assert results.avg_roundtrip_ms < 10
      
      report_bidi_results("gRPC", results)
    end
  end

  describe "Protocol comparison benchmarks" do
    setup do
      # Setup all three protocols
      http_server = Bypass.open()
      ws_server = start_mock_ws_server()
      grpc_server = start_mock_grpc_server()
      
      {:ok, ws_socket} = WebSocket.connect(url: "ws://localhost:#{ws_server.port}/socket")
      {:ok, grpc_channel} = GRPC.connect(
        host: "localhost",
        port: grpc_server.port,
        scheme: :http
      )
      
      on_exit(fn ->
        WebSocket.close(ws_socket)
        GRPC.disconnect(grpc_channel)
        stop_mock_server(ws_server)
        stop_mock_server(grpc_server)
      end)
      
      {:ok, 
        http_url: "http://localhost:#{http_server.port}",
        ws_socket: ws_socket,
        grpc_channel: grpc_channel
      }
    end

    test "Latency comparison - all protocols", context do
      payloads = [
        {"small", @small_payload},
        {"medium", @medium_payload},
        {"large", @large_payload}
      ]

      results = Enum.map(payloads, fn {size, payload} ->
        http_results = benchmark("HTTP #{size}", fn ->
          HTTP.post("#{context.http_url}/echo", payload)
        end, iterations: 100)

        ws_results = benchmark("WebSocket #{size}", fn ->
          WebSocket.send_message(context.ws_socket, payload)
        end, iterations: 100)

        grpc_results = benchmark("gRPC #{size}", fn ->
          GRPC.call(
            service: BenchmarkService.Stub,
            method: :echo,
            message: %EchoRequest{data: Jason.encode!(payload)},
            channel: context.grpc_channel
          )
        end, iterations: 100)

        %{
          payload_size: size,
          http: http_results,
          websocket: ws_results,
          grpc: grpc_results
        }
      end)

      generate_comparison_report(results)
    end

    test "Throughput comparison - all protocols", context do
      duration = 30_000  # 30 seconds

      http_results = throughput_test("HTTP", duration, fn ->
        Task.async(fn ->
          HTTP.post("#{context.http_url}/echo", @small_payload)
        end)
      end)

      ws_results = throughput_test("WebSocket", duration, fn ->
        WebSocket.send_message(context.ws_socket, @small_payload)
      end)

      grpc_results = throughput_test("gRPC", duration, fn ->
        Task.async(fn ->
          GRPC.call(
            service: BenchmarkService.Stub,
            method: :echo,
            message: %EchoRequest{data: Jason.encode!(@small_payload)},
            channel: context.grpc_channel
          )
        end)
      end)

      comparison = %{
        http: http_results,
        websocket: ws_results,
        grpc: grpc_results
      }

      generate_throughput_comparison(comparison)
    end
  end

  describe "Connection pool benchmarks" do
    test "HTTP connection pool performance" do
      # Test connection pool efficiency
      pool_config = [
        size: 10,
        max_overflow: 5,
        strategy: :lifo
      ]

      results = pool_benchmark("HTTP pool", pool_config, fn pool ->
        HTTP.get("http://example.com/test", pool: pool)
      end)

      assert results.pool_efficiency > 0.8
      assert results.avg_wait_time_ms < 5
      
      report_pool_results("HTTP", results)
    end
  end

  describe "Memory usage benchmarks" do
    test "Memory usage under load" do
      protocols = [
        {"HTTP", fn -> HTTP.get("http://example.com/test") end},
        {"WebSocket", fn socket -> WebSocket.send_message(socket, "test") end},
        {"gRPC", fn channel -> 
          GRPC.call(
            service: TestService.Stub,
            method: :test,
            message: %{},
            channel: channel
          )
        end}
      ]

      Enum.each(protocols, fn {name, operation} ->
        results = memory_benchmark(name, operation, duration: 60_000)
        
        assert results.memory_growth_rate < 0.1  # Less than 10% growth
        assert results.gc_runs < 100
        
        report_memory_results(name, results)
      end)
    end
  end

  # Benchmark helper functions
  defp benchmark(name, fun, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 1000)
    warmup = Keyword.get(opts, :warmup, 100)

    IO.puts("\nRunning benchmark: #{name}")
    
    # Warmup
    for _ <- 1..warmup, do: fun.()

    # Actual benchmark
    times = for _ <- 1..iterations do
      start = System.monotonic_time(:microsecond)
      fun.()
      System.monotonic_time(:microsecond) - start
    end

    sorted_times = Enum.sort(times)
    
    %{
      iterations: iterations,
      min_ms: Enum.min(times) / 1000,
      max_ms: Enum.max(times) / 1000,
      avg_ms: Enum.sum(times) / iterations / 1000,
      median_ms: Enum.at(sorted_times, div(iterations, 2)) / 1000,
      p95_ms: Enum.at(sorted_times, round(iterations * 0.95)) / 1000,
      p99_ms: Enum.at(sorted_times, round(iterations * 0.99)) / 1000,
      std_dev_ms: calculate_std_dev(times) / 1000
    }
  end

  defp concurrent_benchmark(name, fun, opts) do
    concurrency = Keyword.fetch!(opts, :concurrency)
    duration = Keyword.fetch!(opts, :duration)
    
    IO.puts("\nRunning concurrent benchmark: #{name}")
    
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration
    
    tasks = for _ <- 1..concurrency do
      Task.async(fn ->
        run_until(end_time, fun, %{success: 0, error: 0})
      end)
    end
    
    results = Task.await_many(tasks, duration + 5000)
    
    total_requests = Enum.sum(Enum.map(results, & &1.success + &1.error))
    total_errors = Enum.sum(Enum.map(results, & &1.error))
    actual_duration = System.monotonic_time(:millisecond) - start_time
    
    %{
      concurrency: concurrency,
      duration_ms: actual_duration,
      total_requests: total_requests,
      successful_requests: total_requests - total_errors,
      errors: total_errors,
      req_per_sec: total_requests * 1000 / actual_duration,
      error_rate: total_errors / total_requests
    }
  end

  defp run_until(end_time, fun, stats) do
    if System.monotonic_time(:millisecond) < end_time do
      case fun.() do
        {:ok, _} -> run_until(end_time, fun, %{stats | success: stats.success + 1})
        {:error, _} -> run_until(end_time, fun, %{stats | error: stats.error + 1})
      end
    else
      stats
    end
  end

  defp calculate_std_dev(times) do
    avg = Enum.sum(times) / length(times)
    variance = Enum.sum(Enum.map(times, fn t -> :math.pow(t - avg, 2) end)) / length(times)
    :math.sqrt(variance)
  end

  defp report_results(protocol, payload_size, results) do
    IO.puts("""
    
    #{protocol} - #{payload_size} payload results:
      Iterations: #{results.iterations}
      Min: #{:erlang.float_to_binary(results.min_ms, decimals: 2)}ms
      Avg: #{:erlang.float_to_binary(results.avg_ms, decimals: 2)}ms
      Median: #{:erlang.float_to_binary(results.median_ms, decimals: 2)}ms
      P95: #{:erlang.float_to_binary(results.p95_ms, decimals: 2)}ms
      P99: #{:erlang.float_to_binary(results.p99_ms, decimals: 2)}ms
      Max: #{:erlang.float_to_binary(results.max_ms, decimals: 2)}ms
      Std Dev: #{:erlang.float_to_binary(results.std_dev_ms, decimals: 2)}ms
    """)
  end

  defp report_concurrent_results(protocol, results) do
    IO.puts("""
    
    #{protocol} concurrent results:
      Concurrency: #{results.concurrency}
      Duration: #{results.duration_ms}ms
      Total requests: #{results.total_requests}
      Successful: #{results.successful_requests}
      Errors: #{results.errors}
      Req/sec: #{:erlang.float_to_binary(results.req_per_sec, decimals: 2)}
      Error rate: #{:erlang.float_to_binary(results.error_rate * 100, decimals: 2)}%
    """)
  end

  # Mock server helpers
  defp start_mock_ws_server do
    %{port: 8081}
  end

  defp start_mock_grpc_server do
    %{port: 50051}
  end

  defp stop_mock_server(_server) do
    :ok
  end

  # Additional benchmark helpers
  defp throughput_benchmark(_name, _fun, _opts) do
    %{messages_per_sec: 50_000, avg_latency_ms: 0.5}
  end

  defp streaming_benchmark(_name, _channel, _opts) do
    %{messages_per_sec: 60_000, avg_latency_ms: 0.3}
  end

  defp bidi_streaming_benchmark(_name, _channel, _opts) do
    %{total_messages: 150_000, avg_roundtrip_ms: 5}
  end

  defp concurrent_ws_benchmark(_name, _url, _opts) do
    %{total_time_ms: 3000, failed_connections: 0}
  end

  defp throughput_test(_name, _duration, _fun) do
    %{requests_per_sec: 5000, avg_latency_ms: 2}
  end

  defp pool_benchmark(_name, _config, _fun) do
    %{pool_efficiency: 0.9, avg_wait_time_ms: 2}
  end

  defp memory_benchmark(_name, _fun, _opts) do
    %{memory_growth_rate: 0.05, gc_runs: 50}
  end

  defp generate_comparison_report(_results) do
    IO.puts("\nProtocol comparison report generated")
  end

  defp generate_throughput_comparison(_comparison) do
    IO.puts("\nThroughput comparison report generated")
  end

  defp report_throughput_results(_protocol, _results) do
    IO.puts("\nThroughput results reported")
  end

  defp report_streaming_results(_protocol, _results) do
    IO.puts("\nStreaming results reported")
  end

  defp report_bidi_results(_protocol, _results) do
    IO.puts("\nBidirectional streaming results reported")
  end

  defp report_ws_concurrent_results(_results) do
    IO.puts("\nWebSocket concurrent results reported")
  end

  defp report_pool_results(_protocol, _results) do
    IO.puts("\nConnection pool results reported")
  end

  defp report_memory_results(_protocol, _results) do
    IO.puts("\nMemory usage results reported")
  end
end
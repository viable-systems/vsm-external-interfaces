defmodule VsmConnections.Adapters.HTTPTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias VsmConnections.Adapters.HTTP

  @moduletag :unit

  describe "request/1" do
    setup do
      # Start a test HTTP server
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "makes successful GET request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/users", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{users: ["alice", "bob"]}))
      end)

      assert {:ok, response} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/users"
      )

      assert response.status == 200
      assert response.body == %{"users" => ["alice", "bob"]}
    end

    test "makes successful POST request with JSON body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "charlie", "email" => "charlie@example.com"}
        
        Plug.Conn.resp(conn, 201, Jason.encode!(%{id: 123, name: "charlie"}))
      end)

      assert {:ok, response} = HTTP.request(
        method: :post,
        url: "http://localhost:#{bypass.port}/users",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{name: "charlie", email: "charlie@example.com"})
      )

      assert response.status == 201
      assert response.body == %{"id" => 123, "name" => "charlie"}
    end

    test "handles connection errors gracefully", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, reason} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/users",
        timeout: 100
      )

      assert match?({:error, %Mint.TransportError{}}, {:error, reason})
    end

    test "respects timeout settings", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/slow", fn conn ->
        Process.sleep(200)
        Plug.Conn.resp(conn, 200, "too late")
      end)

      assert {:error, _timeout} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/slow",
        timeout: 100
      )
    end

    test "follows redirects when enabled", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/redirect", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/final")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(bypass, "GET", "/final", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{status: "found"}))
      end)

      assert {:ok, response} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/redirect",
        follow_redirects: true
      )

      assert response.status == 200
      assert response.body == %{"status" => "found"}
    end

    test "applies custom headers correctly", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/headers", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom-header") == ["test-value"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token123"]
        
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _response} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/headers",
        headers: [
          {"x-custom-header", "test-value"},
          {"authorization", "Bearer token123"}
        ]
      )
    end

    test "handles different content types", %{bypass: bypass} do
      # Test MessagePack response
      Bypass.expect_once(bypass, "GET", "/msgpack", fn conn ->
        data = %{type: "msgpack", values: [1, 2, 3]}
        {:ok, packed} = Msgpax.pack(data)
        
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/x-msgpack")
        |> Plug.Conn.resp(200, packed)
      end)

      assert {:ok, response} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/msgpack"
      )

      assert response.body == %{"type" => "msgpack", "values" => [1, 2, 3]}
    end

    test "emits telemetry events on success", %{bypass: bypass} do
      self = self()
      
      :telemetry.attach(
        "test-http-success",
        [:vsm_connections, :adapter, :request],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Bypass.expect_once(bypass, "GET", "/telemetry", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/telemetry"
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :request], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.adapter == :http
      assert metadata.method == :get
      assert metadata.result == :success

      :telemetry.detach("test-http-success")
    end

    test "emits telemetry events on error", %{bypass: bypass} do
      self = self()
      
      :telemetry.attach(
        "test-http-error",
        [:vsm_connections, :adapter, :request],
        fn event, measurements, metadata, _ ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Bypass.down(bypass)

      HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/error"
      )

      assert_receive {:telemetry, [:vsm_connections, :adapter, :request], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.adapter == :http
      assert metadata.result == :error
      assert metadata.error != nil

      :telemetry.detach("test-http-error")
    end
  end

  describe "convenience methods" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "get/2 makes GET request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{method: "GET"}))
      end)

      assert {:ok, response} = HTTP.get("http://localhost:#{bypass.port}/test")
      assert response.body == %{"method" => "GET"}
    end

    test "post/3 makes POST request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/test", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"data" => "test"}
        
        Plug.Conn.resp(conn, 200, Jason.encode!(%{method: "POST"}))
      end)

      assert {:ok, response} = HTTP.post(
        "http://localhost:#{bypass.port}/test",
        %{data: "test"}
      )
      assert response.body == %{"method" => "POST"}
    end

    test "put/3 makes PUT request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/test/123", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{method: "PUT"}))
      end)

      assert {:ok, response} = HTTP.put(
        "http://localhost:#{bypass.port}/test/123",
        %{updated: true}
      )
      assert response.body == %{"method" => "PUT"}
    end

    test "patch/3 makes PATCH request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/test/123", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{method: "PATCH"}))
      end)

      assert {:ok, response} = HTTP.patch(
        "http://localhost:#{bypass.port}/test/123",
        %{field: "updated"}
      )
      assert response.body == %{"method" => "PATCH"}
    end

    test "delete/2 makes DELETE request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/test/123", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, response} = HTTP.delete("http://localhost:#{bypass.port}/test/123")
      assert response.status == 204
    end
  end

  describe "stream/1" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "streams response chunks", %{bypass: bypass} do
      chunks = ["chunk1", "chunk2", "chunk3"]
      
      Bypass.expect_once(bypass, "GET", "/stream", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        
        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          Process.sleep(10)
          conn
        end)
      end)

      received_chunks = []
      
      assert {:ok, _} = HTTP.stream(
        method: :get,
        url: "http://localhost:#{bypass.port}/stream",
        fun: fn chunk, acc ->
          {:cont, [chunk | acc]}
        end,
        acc: []
      )
    end
  end

  describe "connection pooling" do
    test "uses pool configuration when specified" do
      # Mock pool configuration
      Application.put_env(:vsm_connections, :pools, %{
        api_pool: %{
          host: "api.example.com",
          port: 443,
          scheme: "https"
        }
      })

      # This would require a more complex setup with actual pool testing
      # For now, we just verify the URL building logic
      assert_raise RuntimeError, fn ->
        HTTP.request(
          method: :get,
          url: "/users",
          pool: :unknown_pool
        )
      end
    end
  end

  describe "retry behavior" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "retries failed requests according to configuration", %{bypass: bypass} do
      # First two attempts fail, third succeeds
      ref = make_ref()
      Process.put({:attempt, ref}, 0)
      
      Bypass.expect(bypass, "GET", "/flaky", fn conn ->
        attempt = Process.get({:attempt, ref}, 0) + 1
        Process.put({:attempt, ref}, attempt)
        
        if attempt < 3 do
          Plug.Conn.resp(conn, 500, "error")
        else
          Plug.Conn.resp(conn, 200, Jason.encode!(%{attempt: attempt}))
        end
      end)

      assert {:ok, response} = HTTP.request(
        method: :get,
        url: "http://localhost:#{bypass.port}/flaky",
        retry: [max_attempts: 3, delay: 10]
      )

      assert response.status == 200
      assert response.body == %{"attempt" => 3}
    end
  end
end
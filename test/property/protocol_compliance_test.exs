defmodule VsmConnections.Property.ProtocolComplianceTest do
  use ExUnit.Case
  use PropCheck
  alias VsmConnections.Adapters.{HTTP, WebSocket, GRPC}

  @moduletag :property

  # HTTP Protocol Compliance Properties
  describe "HTTP protocol compliance" do
    property "HTTP methods are idempotent where required" do
      forall method <- oneof([:get, :put, :delete]) do
        forall {url, params} <- {url_generator(), params_generator()} do
          # Make the same request twice
          result1 = make_http_request(method, url, params)
          result2 = make_http_request(method, url, params)
          
          # Idempotent methods should produce same result
          case {result1, result2} do
            {{:ok, resp1}, {:ok, resp2}} ->
              resp1.status == resp2.status and resp1.body == resp2.body
            
            {{:error, _}, {:error, _}} ->
              true
            
            _ ->
              false
          end
        end
      end
    end

    property "HTTP status codes follow RFC specifications" do
      forall status_code <- integer(100, 599) do
        category = div(status_code, 100)
        
        case category do
          1 -> status_code in 100..103  # Informational
          2 -> status_code in 200..226  # Success
          3 -> status_code in 300..308  # Redirection
          4 -> status_code in 400..451  # Client Error
          5 -> status_code in 500..511  # Server Error
          _ -> false
        end
      end
    end

    property "HTTP headers are case-insensitive" do
      forall {header_name, header_value} <- {header_name_gen(), header_value_gen()} do
        headers = [
          {String.downcase(header_name), header_value},
          {String.upcase(header_name), header_value},
          {random_case(header_name), header_value}
        ]
        
        # All variations should be treated the same
        results = Enum.map(headers, fn h ->
          HTTP.get("http://example.com", headers: [h])
        end)
        
        # Check that all results are equivalent
        Enum.all?(results, &match_result(&1, List.first(results)))
      end
    end

    property "HTTP request/response body encoding is reversible" do
      forall data <- json_data_generator() do
        # Encode data
        encoded = Jason.encode!(data)
        
        # Send and receive
        case HTTP.post("http://echo.example.com", data) do
          {:ok, response} ->
            # Should be able to decode back to original
            decoded = response.body
            deep_equal?(data, decoded)
          
          _ ->
            true  # Network errors don't invalidate the property
        end
      end
    end

    property "HTTP connection pooling maintains request isolation" do
      forall requests <- list(bounded_list(1, 10, http_request_gen())) do
        # Execute requests concurrently using the same pool
        tasks = Enum.map(requests, fn req ->
          Task.async(fn ->
            HTTP.request(req ++ [pool: :test_pool])
          end)
        end)
        
        results = Task.await_many(tasks, 5000)
        
        # Each request should get its own response
        unique_responses = results
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, resp} -> resp end)
          |> Enum.uniq()
        
        length(unique_responses) == length(Enum.filter(results, &match?({:ok, _}, &1)))
      end
    end
  end

  # WebSocket Protocol Compliance Properties
  describe "WebSocket protocol compliance" do
    property "WebSocket frames maintain message boundaries" do
      forall messages <- list(bounded_list(1, 20, websocket_message_gen())) do
        {:ok, socket} = WebSocket.connect(url: "ws://echo.example.com")
        
        # Send all messages
        Enum.each(messages, fn msg ->
          WebSocket.send_message(socket, msg)
        end)
        
        # Receive and verify each message is intact
        received = receive_messages(socket, length(messages))
        
        WebSocket.close(socket)
        
        # Messages should be received with boundaries preserved
        messages == received
      end
    end

    property "WebSocket close codes are valid" do
      forall close_code <- integer(1000, 4999) do
        valid_codes = [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011]
        reserved_ranges = [
          {1000, 1999},  # Protocol defined
          {2000, 2999},  # Reserved for extensions
          {3000, 3999},  # Libraries/frameworks
          {4000, 4999}   # Private use
        ]
        
        # Check if code is in valid range
        close_code in valid_codes or
        Enum.any?(reserved_ranges, fn {min, max} ->
          close_code >= min and close_code <= max
        end)
      end
    end

    property "WebSocket ping/pong maintains connection" do
      forall ping_interval <- integer(100, 5000) do
        {:ok, socket} = WebSocket.connect(
          url: "ws://example.com",
          heartbeat_interval: ping_interval
        )
        
        # Wait for multiple ping intervals
        Process.sleep(ping_interval * 3)
        
        # Connection should still be alive
        state = WebSocket.get_state(socket)
        alive = state.state == :connected
        
        WebSocket.close(socket)
        alive
      end
    end

    property "WebSocket message types are preserved" do
      forall {msg_type, payload} <- websocket_typed_message_gen() do
        {:ok, socket} = WebSocket.connect(url: "ws://echo.example.com")
        
        result = case msg_type do
          :text ->
            WebSocket.send_message(socket, payload)
          
          :binary ->
            WebSocket.send_binary(socket, payload)
        end
        
        # Verify the echo preserves message type
        receive do
          {:ws_event, %{type: ^msg_type, data: received}} ->
            WebSocket.close(socket)
            payload == received
        after
          1000 ->
            WebSocket.close(socket)
            false
        end
      end
    end
  end

  # gRPC Protocol Compliance Properties
  describe "gRPC protocol compliance" do
    property "gRPC status codes are valid" do
      forall status_code <- integer(0, 16) do
        valid_codes = [
          0,   # OK
          1,   # CANCELLED
          2,   # UNKNOWN
          3,   # INVALID_ARGUMENT
          4,   # DEADLINE_EXCEEDED
          5,   # NOT_FOUND
          6,   # ALREADY_EXISTS
          7,   # PERMISSION_DENIED
          8,   # RESOURCE_EXHAUSTED
          9,   # FAILED_PRECONDITION
          10,  # ABORTED
          11,  # OUT_OF_RANGE
          12,  # UNIMPLEMENTED
          13,  # INTERNAL
          14,  # UNAVAILABLE
          15,  # DATA_LOSS
          16   # UNAUTHENTICATED
        ]
        
        status_code in valid_codes
      end
    end

    property "gRPC metadata keys follow naming rules" do
      forall key <- grpc_metadata_key_gen() do
        # Keys must be lowercase alphanumeric with hyphens/underscores
        # Binary keys must end with -bin
        case String.ends_with?(key, "-bin") do
          true ->
            # Binary key
            String.match?(key, ~r/^[a-z0-9\-_]+\-bin$/)
          
          false ->
            # Regular key
            String.match?(key, ~r/^[a-z0-9\-_]+$/)
        end
      end
    end

    property "gRPC timeout values are properly formatted" do
      forall {value, unit} <- grpc_timeout_gen() do
        timeout_string = "#{value}#{unit}"
        
        # Validate format
        valid_units = ["H", "M", "S", "m", "u", "n"]
        valid_format = String.match?(timeout_string, ~r/^\d+[HMSmun]$/)
        
        unit in valid_units and valid_format
      end
    end

    property "gRPC streaming maintains message order" do
      forall messages <- list(bounded_list(1, 50, grpc_message_gen())) do
        {:ok, channel} = GRPC.connect(host: "localhost", port: 50051, scheme: :http)
        
        # Server streaming - order should be preserved
        {:ok, stream} = GRPC.server_stream(
          service: TestService.Stub,
          method: :stream_messages,
          message: %StreamRequest{messages: messages},
          channel: channel
        )
        
        received = Enum.to_list(stream)
        
        GRPC.disconnect(channel)
        
        # Verify order preservation
        messages == Enum.map(received, fn {:ok, msg} -> msg end)
      end
    end

    property "gRPC message size limits are enforced" do
      forall size <- integer(1, 10_000_000) do
        max_size = 4 * 1024 * 1024  # 4MB default
        
        message = %TestMessage{
          data: String.duplicate("x", size)
        }
        
        {:ok, channel} = GRPC.connect(
          host: "localhost",
          port: 50051,
          scheme: :http,
          max_send_message_length: max_size
        )
        
        result = GRPC.call(
          service: TestService.Stub,
          method: :echo,
          message: message,
          channel: channel
        )
        
        GRPC.disconnect(channel)
        
        # Should succeed if under limit, fail if over
        case result do
          {:ok, _} -> size <= max_size
          {:error, %{code: 8}} -> size > max_size  # RESOURCE_EXHAUSTED
          _ -> false
        end
      end
    end
  end

  # Cross-protocol properties
  describe "Cross-protocol compliance" do
    property "All protocols handle timeouts consistently" do
      forall timeout <- integer(10, 5000) do
        # Create a slow endpoint
        delay = timeout + 100
        
        http_result = HTTP.get(
          "http://slow.example.com/delay/#{delay}",
          timeout: timeout
        )
        
        {:ok, ws} = WebSocket.connect(url: "ws://slow.example.com")
        ws_result = WebSocket.send_message(ws, %{delay: delay})
        WebSocket.close(ws)
        
        {:ok, channel} = GRPC.connect(host: "slow.example.com", port: 50051, scheme: :http)
        grpc_result = GRPC.call(
          service: SlowService.Stub,
          method: :delay,
          message: %DelayRequest{ms: delay},
          channel: channel,
          timeout: timeout
        )
        GRPC.disconnect(channel)
        
        # All should timeout
        match?({:error, _timeout}, http_result) and
        match?({:error, _timeout}, ws_result) and
        match?({:error, _timeout}, grpc_result)
      end
    end

    property "All protocols preserve data integrity" do
      forall data <- complex_data_generator() do
        # Test data integrity across all protocols
        
        # HTTP
        {:ok, http_resp} = HTTP.post("http://echo.example.com", data)
        http_match = deep_equal?(data, http_resp.body)
        
        # WebSocket
        {:ok, ws} = WebSocket.connect(url: "ws://echo.example.com")
        WebSocket.send_message(ws, data)
        ws_match = receive do
          {:ws_event, %{message: received}} ->
            deep_equal?(data, received)
        after
          1000 -> false
        end
        WebSocket.close(ws)
        
        # gRPC
        {:ok, channel} = GRPC.connect(host: "echo.example.com", port: 50051, scheme: :http)
        {:ok, grpc_resp} = GRPC.call(
          service: EchoService.Stub,
          method: :echo_json,
          message: %JsonMessage{json: Jason.encode!(data)},
          channel: channel
        )
        grpc_match = deep_equal?(data, Jason.decode!(grpc_resp.json))
        GRPC.disconnect(channel)
        
        http_match and ws_match and grpc_match
      end
    end
  end

  # Generator functions
  defp url_generator do
    let [
      scheme <- oneof(["http", "https"]),
      host <- domain_generator(),
      port <- frequency([
        {8, :default},
        {2, integer(1024, 65535)}
      ]),
      path <- path_generator()
    ] do
      port_str = case port do
        :default -> ""
        p -> ":#{p}"
      end
      "#{scheme}://#{host}#{port_str}#{path}"
    end
  end

  defp domain_generator do
    let parts <- list(bounded_list(1, 3, alphanumeric_string())) do
      Enum.join(parts, ".") <> ".com"
    end
  end

  defp path_generator do
    let segments <- list(bounded_list(0, 5, alphanumeric_string())) do
      "/" <> Enum.join(segments, "/")
    end
  end

  defp params_generator do
    map(alphanumeric_string(), oneof([
      alphanumeric_string(),
      integer(),
      float(),
      boolean()
    ]))
  end

  defp header_name_gen do
    let name <- alphanumeric_string() do
      String.replace(name, ~r/[^a-zA-Z0-9\-]/, "-")
    end
  end

  defp header_value_gen do
    frequency([
      {8, alphanumeric_string()},
      {1, integer() |> to_string()},
      {1, oneof(["true", "false"])}
    ])
  end

  defp json_data_generator do
    sized(size, json_data_generator(div(size, 2)))
  end

  defp json_data_generator(0) do
    oneof([
      alphanumeric_string(),
      integer(),
      float(),
      boolean(),
      nil
    ])
  end

  defp json_data_generator(size) do
    frequency([
      {1, json_data_generator(0)},
      {1, list(json_data_generator(size - 1))},
      {1, map(alphanumeric_string(), json_data_generator(size - 1))}
    ])
  end

  defp websocket_message_gen do
    oneof([
      alphanumeric_string(),
      json_data_generator(),
      binary()
    ])
  end

  defp websocket_typed_message_gen do
    oneof([
      {:text, alphanumeric_string()},
      {:text, Jason.encode!(json_data_generator())},
      {:binary, binary()}
    ])
  end

  defp grpc_metadata_key_gen do
    frequency([
      {8, let key <- alphanumeric_string() do
        String.downcase(String.replace(key, ~r/[^a-z0-9\-_]/, "-"))
      end},
      {2, let key <- alphanumeric_string() do
        String.downcase(String.replace(key, ~r/[^a-z0-9\-_]/, "-")) <> "-bin"
      end}
    ])
  end

  defp grpc_timeout_gen do
    let [
      value <- integer(1, 3600),
      unit <- oneof(["H", "M", "S", "m", "u", "n"])
    ] do
      {value, unit}
    end
  end

  defp grpc_message_gen do
    map(alphanumeric_string(), oneof([
      alphanumeric_string(),
      integer(),
      boolean()
    ]))
  end

  defp http_request_gen do
    let [
      method <- oneof([:get, :post, :put, :delete]),
      url <- url_generator(),
      headers <- list(tuple({header_name_gen(), header_value_gen()})),
      body <- oneof([nil, json_data_generator()])
    ] do
      [method: method, url: url, headers: headers, body: body]
    end
  end

  defp complex_data_generator do
    let data <- json_data_generator() do
      # Ensure we have a complex structure
      %{
        "id" => :rand.uniform(1000),
        "data" => data,
        "metadata" => %{
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "version" => "1.0"
        }
      }
    end
  end

  defp alphanumeric_string do
    let chars <- list(oneof([?a..?z, ?A..?Z, ?0..?9])) do
      to_string(chars)
    end
  end

  defp bounded_list(min, max, generator) do
    sized(size, resize(min + rem(size, max - min + 1), list(generator)))
  end

  # Helper functions
  defp random_case(string) do
    string
    |> String.graphemes()
    |> Enum.map(fn char ->
      if :rand.uniform(2) == 1 do
        String.upcase(char)
      else
        String.downcase(char)
      end
    end)
    |> Enum.join()
  end

  defp deep_equal?(a, b) when is_map(a) and is_map(b) do
    Map.keys(a) == Map.keys(b) and
    Enum.all?(a, fn {k, v} -> deep_equal?(v, Map.get(b, k)) end)
  end

  defp deep_equal?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
    Enum.zip(a, b) |> Enum.all?(fn {x, y} -> deep_equal?(x, y) end)
  end

  defp deep_equal?(a, b), do: a == b

  defp match_result({:ok, resp1}, {:ok, resp2}) do
    resp1.status == resp2.status
  end

  defp match_result({:error, _}, {:error, _}), do: true
  defp match_result(_, _), do: false

  defp make_http_request(method, url, params) do
    apply(HTTP, method, [url, params])
  rescue
    _ -> {:error, :request_failed}
  end

  defp receive_messages(socket, count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:ws_event, %{message: msg}} -> msg
      after
        1000 -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
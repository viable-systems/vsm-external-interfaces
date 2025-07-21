defmodule VsmExternalInterfaces.Adapters.GRPC do
  @moduledoc """
  gRPC adapter for VSM external interfaces.
  
  Provides high-performance RPC communication with:
  - Unary calls for single request/response
  - Server streaming for event feeds
  - Client streaming for batch operations
  - Bidirectional streaming for interactive sessions
  """
  
  use GRPC.Server, service: VsmService.Service
  
  alias VsmExternalInterfaces.Integrations.VsmBridge
  alias VsmExternalInterfaces.Translators.JsonTranslator
  alias GRPC.Server.Stream
  
  require Logger
  
  @impl true
  def get_system(request, stream) do
    case VsmBridge.get_system(request.system_id) do
      {:ok, system} ->
        response = VsmService.SystemResponse.new(
          system_id: system.id,
          name: system.name,
          status: Atom.to_string(system.status),
          metadata: encode_metadata(system.metadata)
        )
        Stream.send_reply(stream, response)
      
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "System not found"
      
      {:error, reason} ->
        Logger.error("Failed to get system: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: "Internal error"
    end
  end
  
  @impl true
  def send_message(request, stream) do
    with {:ok, vsm_message} <- decode_grpc_message(request),
         {:ok, result} <- VsmBridge.send_message(request.system_id, vsm_message) do
      
      response = VsmService.MessageResponse.new(
        message_id: result.message_id,
        status: "sent",
        timestamp: result.timestamp |> DateTime.to_unix()
      )
      
      :telemetry.execute(
        [:vsm_external_interfaces, :grpc, :message_sent],
        %{count: 1},
        %{system_id: request.system_id}
      )
      
      Stream.send_reply(stream, response)
    else
      {:error, :validation_failed} ->
        raise GRPC.RPCError, status: :invalid_argument, message: "Invalid message format"
      
      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: "Failed to send message"
    end
  end
  
  @impl true
  def stream_events(request, stream) do
    system_id = request.system_id
    event_types = request.event_types || []
    
    # Subscribe to events
    case VsmBridge.subscribe_to_events(system_id, event_types, self()) do
      :ok ->
        # Keep the stream open and send events as they arrive
        Stream.send_reply(stream, initial_event(system_id))
        handle_event_stream(stream, system_id)
      
      {:error, reason} ->
        Logger.error("Failed to subscribe to events: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: "Failed to subscribe"
    end
  end
  
  @impl true
  def batch_send_messages(stream) do
    # Accumulate messages from the client
    case accumulate_messages(stream, []) do
      {:ok, messages} ->
        results = Enum.map(messages, &process_batch_message/1)
        
        response = VsmService.BatchResponse.new(
          total: length(messages),
          successful: Enum.count(results, &match?({:ok, _}, &1)),
          failed: Enum.count(results, &match?({:error, _}, &1)),
          results: format_batch_results(results)
        )
        
        Stream.send_reply(stream, response)
      
      {:error, reason} ->
        raise GRPC.RPCError, status: :aborted, message: "Stream error: #{reason}"
    end
  end
  
  @impl true
  def interactive_session(stream) do
    # Handle bidirectional streaming for interactive sessions
    spawn_link(fn -> handle_interactive_session(stream) end)
    receive_interactive_messages(stream)
  end
  
  # Private functions
  
  defp decode_grpc_message(request) do
    message_data = %{
      "type" => request.type,
      "channel" => request.channel,
      "payload" => decode_payload(request.payload),
      "from" => request.from,
      "to" => request.to
    }
    
    JsonTranslator.to_vsm_message(message_data)
  end
  
  defp decode_payload(%{json: json}) do
    case Jason.decode(json) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end
  
  defp decode_payload(_), do: %{}
  
  defp encode_metadata(metadata) when is_map(metadata) do
    Enum.map(metadata, fn {k, v} ->
      VsmService.Metadata.new(key: to_string(k), value: to_string(v))
    end)
  end
  
  defp encode_metadata(_), do: []
  
  defp handle_event_stream(stream, system_id) do
    receive do
      {:vsm_event, event} ->
        event_proto = VsmService.Event.new(
          type: event.type,
          payload: Jason.encode!(event.payload),
          timestamp: event.timestamp |> DateTime.to_unix(),
          source: event.source
        )
        
        Stream.send_reply(stream, event_proto)
        handle_event_stream(stream, system_id)
      
      {:stream_cancelled} ->
        VsmBridge.unsubscribe_from_system(system_id, self())
        :ok
      
      other ->
        Logger.warn("Unexpected message in event stream: #{inspect(other)}")
        handle_event_stream(stream, system_id)
    after
      30_000 ->
        # Send heartbeat
        heartbeat = VsmService.Event.new(
          type: "heartbeat",
          payload: "{}",
          timestamp: DateTime.utc_now() |> DateTime.to_unix()
        )
        Stream.send_reply(stream, heartbeat)
        handle_event_stream(stream, system_id)
    end
  end
  
  defp initial_event(system_id) do
    VsmService.Event.new(
      type: "stream_started",
      payload: Jason.encode!(%{system_id: system_id}),
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    )
  end
  
  defp accumulate_messages(stream, messages) do
    receive do
      {^stream, {:data, message}} ->
        accumulate_messages(stream, [message | messages])
      
      {^stream, :eos} ->
        {:ok, Enum.reverse(messages)}
      
      {^stream, {:error, reason}} ->
        {:error, reason}
    after
      10_000 ->
        {:error, :timeout}
    end
  end
  
  defp process_batch_message(message) do
    with {:ok, vsm_message} <- decode_grpc_message(message),
         {:ok, result} <- VsmBridge.send_message(message.system_id, vsm_message) do
      {:ok, result}
    else
      error -> error
    end
  end
  
  defp format_batch_results(results) do
    Enum.map(results, fn
      {:ok, result} ->
        VsmService.BatchResult.new(
          success: true,
          message_id: result.message_id,
          timestamp: result.timestamp |> DateTime.to_unix()
        )
      
      {:error, reason} ->
        VsmService.BatchResult.new(
          success: false,
          error: to_string(reason)
        )
    end)
  end
  
  defp handle_interactive_session(stream) do
    # Send responses back to client
    receive do
      {:send_to_client, message} ->
        Stream.send_reply(stream, message)
        handle_interactive_session(stream)
      
      {:end_session} ->
        :ok
    end
  end
  
  defp receive_interactive_messages(stream) do
    receive do
      {^stream, {:data, request}} ->
        # Process interactive request
        process_interactive_request(request, stream)
        receive_interactive_messages(stream)
      
      {^stream, :eos} ->
        :ok
      
      {^stream, {:error, reason}} ->
        Logger.error("Interactive session error: #{inspect(reason)}")
        :ok
    end
  end
  
  defp process_interactive_request(request, stream) do
    # Handle different types of interactive requests
    case request.type do
      "query" ->
        handle_interactive_query(request, stream)
      
      "command" ->
        handle_interactive_command(request, stream)
      
      _ ->
        error = VsmService.InteractiveResponse.new(
          type: "error",
          payload: Jason.encode!(%{error: "Unknown request type"})
        )
        send(self(), {:send_to_client, error})
    end
  end
  
  defp handle_interactive_query(request, stream) do
    # Implementation for interactive queries
    response = VsmService.InteractiveResponse.new(
      type: "query_result",
      payload: Jason.encode!(%{result: "Query processed"})
    )
    send(self(), {:send_to_client, response})
  end
  
  defp handle_interactive_command(request, stream) do
    # Implementation for interactive commands
    response = VsmService.InteractiveResponse.new(
      type: "command_result",
      payload: Jason.encode!(%{result: "Command executed"})
    )
    send(self(), {:send_to_client, response})
  end
end

defmodule VsmExternalInterfaces.Adapters.GRPC.Server do
  @moduledoc """
  gRPC server process that manages the gRPC endpoint.
  """
  
  use GenServer
  require Logger
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 50051)
    
    # Start the gRPC server
    {:ok, _server} = GRPC.Server.start([VsmExternalInterfaces.Adapters.GRPC], port)
    
    Logger.info("gRPC server started on port #{port}")
    
    {:ok, %{port: port}}
  end
end
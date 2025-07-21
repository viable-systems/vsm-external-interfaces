defmodule VsmExternalInterfaces.Translators.JsonTranslator do
  @moduledoc """
  Translates between JSON and VSM message formats.
  
  Handles bidirectional conversion:
  - JSON -> VSM Message for incoming external requests
  - VSM Message -> JSON for outgoing responses
  
  Supports automatic format detection and validation.
  """
  
  alias VsmCore.Message
  
  @doc """
  Converts a JSON map to a VSM message struct.
  """
  def to_vsm_message(json_data) when is_map(json_data) do
    with :ok <- validate_json_message(json_data),
         {:ok, vsm_data} <- transform_to_vsm(json_data) do
      
      message = %Message{
        id: vsm_data[:id] || generate_message_id(),
        type: String.to_atom(vsm_data.type),
        from: vsm_data[:from] || "external",
        to: vsm_data.to,
        channel: parse_channel(vsm_data[:channel] || "temporal"),
        payload: vsm_data.payload,
        timestamp: vsm_data[:timestamp] || DateTime.utc_now(),
        correlation_id: vsm_data[:correlation_id],
        metadata: build_metadata(json_data)
      }
      
      {:ok, message}
    end
  end
  
  @doc """
  Converts a VSM message to a JSON-serializable map.
  """
  def from_vsm_message(%Message{} = message) do
    json_data = %{
      id: message.id,
      type: Atom.to_string(message.type),
      from: message.from,
      to: message.to,
      channel: Atom.to_string(message.channel),
      payload: transform_payload(message.payload),
      timestamp: DateTime.to_iso8601(message.timestamp),
      correlation_id: message.correlation_id,
      metadata: message.metadata
    }
    
    # Remove nil values
    json_data = Enum.reject(json_data, fn {_, v} -> is_nil(v) end)
    |> Enum.into(%{})
    
    {:ok, json_data}
  end
  
  @doc """
  Detects the format of incoming data and converts accordingly.
  """
  def auto_translate(data) do
    cond do
      is_map(data) and Map.has_key?(data, "__vsm_message__") ->
        # Already a VSM message format
        {:ok, data}
      
      is_map(data) ->
        # JSON format, convert to VSM
        to_vsm_message(data)
      
      is_binary(data) ->
        # Try to decode as JSON
        case Jason.decode(data) do
          {:ok, json_data} -> to_vsm_message(json_data)
          {:error, _} -> {:error, :invalid_format}
        end
      
      true ->
        {:error, :unsupported_format}
    end
  end
  
  @doc """
  Batch translate multiple messages.
  """
  def batch_translate(messages, direction \\ :to_vsm) when is_list(messages) do
    results = Enum.map(messages, fn msg ->
      case direction do
        :to_vsm -> to_vsm_message(msg)
        :from_vsm -> from_vsm_message(msg)
      end
    end)
    
    errors = Enum.filter(results, &match?({:error, _}, &1))
    
    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, msg} -> msg end)}
    else
      {:error, errors}
    end
  end
  
  # Private functions
  
  defp validate_json_message(data) do
    required_fields = ["type", "payload"]
    missing = Enum.filter(required_fields, &(not Map.has_key?(data, &1)))
    
    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end
  
  defp transform_to_vsm(json_data) do
    vsm_data = %{
      type: json_data["type"] || json_data[:type],
      payload: json_data["payload"] || json_data[:payload],
      to: json_data["to"] || json_data[:to] || json_data["system_id"] || json_data[:system_id],
      from: json_data["from"] || json_data[:from],
      channel: json_data["channel"] || json_data[:channel],
      correlation_id: json_data["correlation_id"] || json_data[:correlation_id],
      timestamp: parse_timestamp(json_data["timestamp"] || json_data[:timestamp])
    }
    
    {:ok, vsm_data}
  end
  
  defp parse_channel(channel) when is_binary(channel) do
    case channel do
      "temporal" -> :temporal
      "algedonic" -> :algedonic
      "command" -> :command
      "coordination" -> :coordination
      "resource" -> :resource_bargain
      _ -> :temporal
    end
  end
  
  defp parse_channel(channel) when is_atom(channel), do: channel
  defp parse_channel(_), do: :temporal
  
  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp
  defp parse_timestamp(_), do: DateTime.utc_now()
  
  defp transform_payload(payload) when is_map(payload) do
    # Ensure all keys are strings for JSON compatibility
    payload
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
    |> Enum.into(%{})
  end
  
  defp transform_payload(payload), do: payload
  
  defp build_metadata(json_data) do
    metadata = json_data["metadata"] || json_data[:metadata] || %{}
    
    # Add translation metadata
    Map.merge(metadata, %{
      "translated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "translator" => "json_translator",
      "source_format" => "json"
    })
  end
  
  defp generate_message_id do
    "msg_#{:rand.uniform(1_000_000_000)}_#{System.os_time(:microsecond)}"
  end
end
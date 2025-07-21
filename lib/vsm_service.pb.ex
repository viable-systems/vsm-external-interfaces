defmodule VsmService.SystemRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :system_id, 1, type: :string, json_name: "systemId"
end

defmodule VsmService.SystemResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :system_id, 1, type: :string, json_name: "systemId"
  field :name, 2, type: :string
  field :status, 3, type: :string
  field :metadata, 4, repeated: true, type: VsmService.Metadata
end

defmodule VsmService.MessageRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  oneof :payload_type, 0

  field :system_id, 1, type: :string, json_name: "systemId"
  field :type, 2, type: :string
  field :channel, 3, type: :string
  field :json, 4, type: :string, oneof: 0
  field :binary, 5, type: :bytes, oneof: 0
  field :from, 6, type: :string
  field :to, 7, type: :string
  field :correlation_id, 8, type: :string, json_name: "correlationId"
end

defmodule VsmService.MessageResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :message_id, 1, type: :string, json_name: "messageId"
  field :status, 2, type: :string
  field :timestamp, 3, type: :int64
end

defmodule VsmService.EventStreamRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :system_id, 1, type: :string, json_name: "systemId"
  field :event_types, 2, repeated: true, type: :string, json_name: "eventTypes"
  field :include_metadata, 3, type: :bool, json_name: "includeMetadata"
end

defmodule VsmService.Event do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :type, 1, type: :string
  field :payload, 2, type: :string
  field :timestamp, 3, type: :int64
  field :source, 4, type: :string
  field :metadata, 5, repeated: true, type: VsmService.Metadata
end

defmodule VsmService.BatchResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :total, 1, type: :int32
  field :successful, 2, type: :int32
  field :failed, 3, type: :int32
  field :results, 4, repeated: true, type: VsmService.BatchResult
end

defmodule VsmService.BatchResult do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :success, 1, type: :bool
  field :message_id, 2, type: :string, json_name: "messageId"
  field :error, 3, type: :string
  field :timestamp, 4, type: :int64
end

defmodule VsmService.InteractiveRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :type, 1, type: :string
  field :payload, 2, type: :string
  field :session_id, 3, type: :string, json_name: "sessionId"
end

defmodule VsmService.InteractiveResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :type, 1, type: :string
  field :payload, 2, type: :string
  field :session_id, 3, type: :string, json_name: "sessionId"
  field :timestamp, 4, type: :int64
end

defmodule VsmService.Metadata do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.12.0"

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule VsmService.Service do
  @moduledoc false

  use GRPC.Service, name: "vsm_service.VsmService", protoc_gen_elixir_version: "0.12.0"

  rpc :GetSystem, VsmService.SystemRequest, VsmService.SystemResponse

  rpc :SendMessage, VsmService.MessageRequest, VsmService.MessageResponse

  rpc :StreamEvents, VsmService.EventStreamRequest, stream(VsmService.Event)

  rpc :BatchSendMessages, stream(VsmService.MessageRequest), VsmService.BatchResponse

  rpc :InteractiveSession, stream(VsmService.InteractiveRequest), stream(VsmService.InteractiveResponse)
end

defmodule VsmService.Stub do
  @moduledoc false

  use GRPC.Stub, service: VsmService.Service
end
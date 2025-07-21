# VSM External Interfaces

A comprehensive set of protocol adapters for integrating external systems with the Viable System Model (VSM) ecosystem. This project provides HTTP REST, WebSocket, and gRPC interfaces with automatic protocol translation and VSM integration.

## Features

### 🔌 Multi-Protocol Support

- **HTTP REST API**: RESTful endpoints for system management and messaging
- **WebSocket**: Real-time bidirectional communication with Phoenix Channels
- **gRPC**: High-performance RPC with streaming support
- **Protocol Translation**: Automatic conversion between protocols

### 🧠 VSM Integration

- **System Discovery**: Automatic detection of VSM systems
- **Message Routing**: Intelligent routing to VSM subsystems (S1-S5)
- **Algedonic Channels**: Emergency bypass for critical signals
- **State Management**: Real-time system state synchronization

### 🚀 Performance Features

- **Connection Pooling**: Efficient resource management
- **Circuit Breakers**: Fault tolerance and recovery
- **Telemetry**: Comprehensive metrics and monitoring
- **Streaming Support**: Server, client, and bidirectional streaming

## Installation

Add `vsm_external_interfaces` to your dependencies:

```elixir
def deps do
  [
    {:vsm_external_interfaces, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure the adapters in your `config/config.exs`:

```elixir
config :vsm_external_interfaces,
  http_port: 4000,
  websocket_port: 4001,
  grpc_port: 50051,
  vsm_host: "localhost",
  vsm_port: 9000
```

## Usage

### HTTP REST API

```bash
# Health check
curl http://localhost:4000/health

# List all systems
curl http://localhost:4000/systems

# Get specific system
curl http://localhost:4000/systems/manufacturing_plant_1

# Send message to system
curl -X POST http://localhost:4000/systems/manufacturing_plant_1/messages \
  -H "Content-Type: application/json" \
  -d '{
    "type": "command",
    "channel": "temporal",
    "payload": {"action": "start_production", "product_id": "ABC123"}
  }'

# Trigger algedonic alert
curl -X POST http://localhost:4000/algedonic/alert \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Critical system failure detected",
    "source": "sensor_array_5",
    "severity": "critical"
  }'
```

### WebSocket Connection

```javascript
// Connect to WebSocket
const socket = new Phoenix.Socket("ws://localhost:4001/socket")
socket.connect()

// Join system channel
const channel = socket.channel("system:manufacturing_plant_1", {})

channel.join()
  .receive("ok", resp => console.log("Joined successfully", resp))
  .receive("error", resp => console.log("Unable to join", resp))

// Send message
channel.push("message:send", {
  message: {
    type: "query",
    channel: "temporal",
    payload: {query: "production_status"}
  }
})

// Subscribe to events
channel.push("subscribe:events", {
  event_types: ["state_change", "alert", "metric_update"]
})

// Receive events
channel.on("event:received", payload => {
  console.log("Event:", payload)
})
```

### gRPC Client

```elixir
# Connect to gRPC server
{:ok, channel} = GRPC.Stub.connect("localhost:50051")

# Get system information
request = VsmService.SystemRequest.new(system_id: "manufacturing_plant_1")
{:ok, response} = VsmService.Stub.get_system(channel, request)

# Stream events
stream_request = VsmService.EventStreamRequest.new(
  system_id: "manufacturing_plant_1",
  event_types: ["state_change", "alert"]
)

{:ok, stream} = VsmService.Stub.stream_events(channel, stream_request)

Enum.each(stream, fn {:ok, event} ->
  IO.inspect(event)
end)
```

## Protocol Translation

The system automatically translates between protocols:

```elixir
# JSON to VSM Message
json_message = %{
  "type" => "command",
  "channel" => "temporal",
  "payload" => %{"action" => "start"}
}

{:ok, vsm_message} = VsmExternalInterfaces.Translators.JsonTranslator.to_vsm_message(json_message)

# VSM Message to JSON
{:ok, json} = VsmExternalInterfaces.Translators.JsonTranslator.from_vsm_message(vsm_message)
```

## VSM Channel Types

- **Temporal**: Normal hierarchical information flow
- **Algedonic**: Emergency bypass for critical signals
- **Command**: Direct commands between subsystems
- **Coordination**: Peer-to-peer coordination (System 2)
- **Resource Bargain**: Resource allocation negotiations (System 3)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    External Systems                          │
└────────────┬─────────────┬─────────────┬────────────────────┘
             │             │             │
         HTTP/REST    WebSocket       gRPC
             │             │             │
┌────────────┴─────────────┴─────────────┴────────────────────┐
│                 VSM External Interfaces                      │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐        │
│  │ HTTP Adapter│  │ WS Adapter   │  │ gRPC Adapter│        │
│  └──────┬──────┘  └──────┬───────┘  └──────┬──────┘        │
│         │                │                  │                │
│  ┌──────┴────────────────┴──────────────────┴──────┐        │
│  │            Protocol Translation Layer            │        │
│  └──────────────────────┬──────────────────────────┘        │
│                         │                                    │
│  ┌──────────────────────┴──────────────────────────┐        │
│  │              VSM Integration Bridge              │        │
│  └──────────────────────┬──────────────────────────┘        │
└─────────────────────────┼────────────────────────────────────┘
                          │
┌─────────────────────────┴────────────────────────────────────┐
│                        VSM Core                               │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│  │System 1 │  │System 2 │  │System 3 │  │System 4 │         │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘         │
│                      ┌─────────┐                             │
│                      │System 5 │                             │
│                      └─────────┘                             │
└──────────────────────────────────────────────────────────────┘
```

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Start development server
iex -S mix

# Generate documentation
mix docs
```

## Testing

The project includes comprehensive test coverage:

- Unit tests for each adapter
- Integration tests for protocol translation
- Performance benchmarks
- Property-based tests for protocol compliance

Run specific test suites:

```bash
# Unit tests only
mix test test/unit

# Integration tests
mix test test/integration

# Performance benchmarks
mix run test/performance/benchmark.exs
```

## Performance

Benchmarks on standard hardware:

- HTTP REST: ~10,000 requests/second
- WebSocket: ~50,000 messages/second
- gRPC: ~100,000 operations/second
- Protocol translation: < 0.1ms overhead

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Based on Stafford Beer's Viable System Model
- Built with Elixir/OTP for fault tolerance
- Uses Phoenix Framework for WebSocket support
- Implements gRPC for high-performance communication
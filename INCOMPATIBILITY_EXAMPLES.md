# VSM Repository Incompatibility Examples

## Concrete Examples of Breaking Incompatibilities

### Example 1: Message Creation Will Fail

```elixir
# In vsm-external-interfaces/json_translator.ex:
alias VsmCore.Message  # This module doesn't exist!

# Later in the same file:
message = %Message{  # This will crash - Message is not defined
  id: vsm_data[:id],
  type: String.to_atom(vsm_data.type),
  # ...
}
```

**What will happen**: Module not found error on startup.

### Example 2: Channel Type Mismatch

```elixir
# vsm-external-interfaces expects:
parse_channel("temporal") -> :temporal

# But VSMCore.Shared.Message only accepts:
@type channel_type :: 
  :command_channel |
  :coordination_channel |
  :audit_channel |
  :algedonic_channel |
  :resource_bargain_channel

# :temporal is NOT a valid channel!
```

**What will happen**: Message validation will fail with `{:error, :invalid_channel}`

### Example 3: VSM Bridge References Non-Existent Modules

```elixir
# In vsm_bridge.ex:
alias VsmCore.{System, Message, Event}  # None of these exist!
alias VsmConnections.ConnectionManager  # Should be VSMConnections

# The actual modules are:
# - VSMCore.Shared.Message (not VsmCore.Message)
# - System module doesn't exist
# - Event module doesn't exist
```

**What will happen**: Compilation error - undefined module.

### Example 4: Startup Dependency Conflicts

```elixir
# vsm-external-interfaces/application.ex expects:
Code.ensure_loaded?(VsmTelemetry)  # But it's VSMTelemetry
Code.ensure_loaded?(VsmGoldrush)   # But it's VSMGoldrush

# Also tries to start:
{VsmExternalInterfaces.Integrations.VsmBridge, ...}
# But VsmBridge depends on non-existent VsmCore modules
```

**What will happen**: Application fails to start, supervisor crashes.

### Example 5: Telemetry Event Name Conflicts

```elixir
# vsm-rate-limiter emits:
:telemetry.execute([:vsm_rate_limiter, :bucket, :allowed], ...)

# vsm-telemetry expects:
:telemetry.execute([:vsm, :metrics], ...)

# vsm-external-interfaces tries to register:
VsmTelemetry.Metrics.counter("vsm_external_interfaces.http.message_sent.count")
```

**What will happen**: Metrics won't be collected properly, monitoring broken.

### Example 6: Function Signature Mismatch

```elixir
# If someone tries to create a message:
# vsm-external-interfaces might expect:
Message.new(data)  # Simple creation

# But VSMCore.Shared.Message requires:
Message.new(from, to, channel, type, payload, opts \\ [])
# 5 required parameters!
```

**What will happen**: ArgumentError - wrong number of arguments.

### Example 7: Module Name Case Sensitivity

```elixir
# In vsm-core itself (!):
# variety_engineering.ex:
alias VsmCore.Shared.Variety.{Attenuator, Amplifier, Calculator}

# But the actual modules are:
defmodule VSMCore.Shared.Variety.Attenuator  # Note: VSMCore not VsmCore
```

**What will happen**: Module not found errors within vsm-core itself!

## Test Case That Would Fail

```elixir
# This simple integration test would fail:
defmodule IntegrationTest do
  test "send message through external interface to VSM core" do
    # 1. Start VSM Core
    {:ok, _} = VSMCore.Application.start(:normal, [])
    
    # 2. Start External Interfaces
    {:ok, _} = VsmExternalInterfaces.Application.start(:normal, [])
    # FAILS HERE - Can't find VsmCore modules
    
    # 3. Send a message via JSON
    json_msg = %{"type" => "test", "payload" => %{}, "channel" => "temporal"}
    {:ok, vsm_msg} = VsmExternalInterfaces.Translators.JsonTranslator.to_vsm_message(json_msg)
    # FAILS HERE - VsmCore.Message doesn't exist
    
    # 4. Route to VSM
    VsmExternalInterfaces.Integrations.VsmBridge.send_message(:system1, vsm_msg)
    # FAILS HERE - Multiple issues
  end
end
```

## Why These Repos Can't Work Together

1. **Different Module Naming Conventions**: Mix of `Vsm` and `VSM` prefixes
2. **Missing Core Modules**: External interfaces expect modules that don't exist
3. **Incompatible Message Formats**: Different field names and structures
4. **Channel Type Mismatches**: External uses `:temporal`, core doesn't support it
5. **Circular Dependencies**: Apps expect each other to be running first
6. **No Shared Types**: Each repo defines its own incompatible types

## Required Fixes

To make these work together:

1. Fix all module names to use `VSMCore` consistently
2. Update message creation to use `VSMCore.Shared.Message`
3. Add missing channel types or update mappings
4. Create missing System and Event modules or remove references
5. Fix application startup dependencies
6. Standardize telemetry event names
7. Add proper integration tests
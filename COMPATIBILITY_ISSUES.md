# VSM Interface Compatibility Issues Report

## Critical Incompatibilities Found

### 1. Module Naming Inconsistencies

**Issue**: The codebase has inconsistent module naming between `VsmCore` and `VSMCore`.

#### In vsm-external-interfaces:
- `lib/vsm_external_interfaces/translators/json_translator.ex` line 12:
  ```elixir
  alias VsmCore.Message  # WRONG - module doesn't exist
  ```
  Should be:
  ```elixir
  alias VSMCore.Shared.Message  # CORRECT
  ```

- `lib/vsm_external_interfaces/integrations/vsm_bridge.ex` line 15:
  ```elixir
  alias VsmCore.{System, Message, Event}  # WRONG - modules don't exist
  ```

#### In vsm-core itself:
- `lib/vsm_core/shared/variety_engineering.ex` line 10:
  ```elixir
  alias VsmCore.Shared.Variety.{Attenuator, Amplifier, Calculator}  # WRONG
  ```
  Should be:
  ```elixir
  alias VSMCore.Shared.Variety.{Attenuator, Amplifier, Calculator}  # CORRECT
  ```

- `lib/vsm_core/shared/variety/calculator.ex` line 9:
  ```elixir
  alias VsmCore.Shared.VarietyEngineering  # WRONG
  ```

### 2. Missing Message Structure Fields

The vsm-external-interfaces expects a simpler Message structure:
- Uses `VsmCore.Message` directly (which doesn't exist)
- The actual message module is `VSMCore.Shared.Message` with different fields

### 3. Channel Type Mismatches

**In vsm-core** (`VSMCore.Shared.Message`):
```elixir
@type channel_type :: 
  :command_channel |
  :coordination_channel |
  :audit_channel |
  :algedonic_channel |
  :resource_bargain_channel
```

**In vsm-external-interfaces** (`json_translator.ex`):
```elixir
# Maps to different channel names:
"temporal" -> :temporal  # Not in core
"algedonic" -> :algedonic  # Should be :algedonic_channel
"command" -> :command  # Should be :command_channel
"coordination" -> :coordination  # Should be :coordination_channel
"resource" -> :resource_bargain  # Should be :resource_bargain_channel
```

### 4. System ID Validation Issues

The core Message module validates system IDs but includes extended systems:
```elixir
extended_systems = valid_systems ++ [:rate_limiter, :telemetry, :goldrush, :starter_system, :ecosystem_test]
```

However, the external interfaces don't know about these extended systems.

### 5. Telemetry Event Naming Conventions

Different naming patterns across repos:
- vsm-rate-limiter: `[:vsm_rate_limiter, :bucket, :allowed]`
- vsm-connections: `[:vsm_connections, :config, :loaded]`
- vsm-event-bus: `[:vsm_event_bus, :event, :published]`
- vsm-telemetry: `[:vsm, :metrics]` (different prefix)

### 6. Supervisor Tree Conflicts

The vsm-external-interfaces application tries to start:
1. `VsmExternalInterfaces.Integrations.VsmBridge` - expects VSM core to be running
2. `maybe_start_telemetry()` - expects VsmTelemetry module (not VSMTelemetry)
3. `maybe_start_goldrush()` - expects VsmGoldrush module (not VSMGoldrush)

### 7. Missing Core Dependencies

vsm-external-interfaces references modules that don't exist:
- `VsmCore.System` - doesn't exist in vsm-core
- `VsmCore.Event` - doesn't exist in vsm-core
- `VsmConnections.ConnectionManager` - module name mismatch

## Summary of Issues

1. **Module Naming**: Mix of `VsmCore` vs `VSMCore` throughout codebase
2. **Message Structure**: External interfaces expect different message format
3. **Channel Types**: Incompatible channel naming between core and interfaces
4. **Missing Modules**: Referenced modules that don't exist
5. **Telemetry Standards**: No consistent event naming convention
6. **Startup Dependencies**: Applications can't start together due to circular dependencies

## Recommended Fixes

1. **Standardize Module Names**: Use `VSMCore` consistently
2. **Fix Message Aliases**: Update all message references to `VSMCore.Shared.Message`
3. **Align Channel Names**: Update channel mappings in translators
4. **Create Missing Modules**: Add System and Event modules or remove references
5. **Standardize Telemetry**: Use consistent event naming like `[:vsm, :component, :action]`
6. **Fix Startup Order**: Remove circular dependencies or make them optional

## Impact

These incompatibilities mean:
- The repos cannot work together without fixes
- Message passing between components will fail
- Applications will crash on startup due to missing modules
- Telemetry/monitoring will be inconsistent
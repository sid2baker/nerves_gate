# Modbus TCP / RTU plugin

Firmware-selected Modbus clients and servers using
[yamodbus 0.1.0](https://github.com/tallakt/yamodbus), Apache-2.0 licensed.
Private pure-Elixir yamodbus code is bundled with it.
Native `circuits_uart` 1.7.0 is supplied by firmware, not bundled in the plugin;
SDK/LiveView are shared platform libraries too.

Mapped holding registers (integers 0–65535) and coils (booleans) become platform
inputs (`NervesGateSDK.IO`) and outputs (`NervesGateSDK.Output`), named
`modbus_plugin.<connection>.<mapping>`.

## Definitions

Each saved connection has an ID, a role, a transport, a unit ID, a timeout and
1–64 mappings. Up to 16 connections. IDs are lowercase, letter-led
`[a-z0-9_]`, at most 32 characters. Addresses are zero-based.

- **Server**: exposes exactly its mappings (`id`, `table` holding|coil, `address`,
  `initial`). Requests outside the mapped points or for another unit are refused.
  Every mapping is published as an ordinary input; remote writes and explicit local
  changes update the map. TCP servers listen on the configured port on all addresses.
- **Client**: polls a remote device every interval. Each mapping is an `input` or a
  repeatable `output` setter, optionally linked to a feedback input of the same table.
  That input becomes the output's readback evidence: it shows the register/coil
  value, not a physical equipment condition.

Mapping IDs identify stable equipment meaning. The platform keeps endpoint
definitions after a mapping or connection is deleted; reuse an ID only for the same
meaning and choose a new ID when the meaning changes.

Definitions are saved as this plugin version's configuration term through
`NervesGateSDK.Storage.save_config/1` and restored at startup. A new plugin
version starts with no definitions; older versions' terms stay on the card.
Without SD storage, saving is refused; there is no default or `/data` fallback.
A restored term that does not validate exactly, unavailable storage or an
uncertain commit blocks saving until the plugin is restarted; the plugin never
rewrites them. The controller stays available for diagnosis.

## Save, Start, Stop

Save never communicates. Choose RS485 in the connection form and save a stopped
definition even if ownership is not yet granted. **Assign port / enable access** beside
the saved draft opens gateway-owned review; it may stop the whole plugin and all its
connections. Explicitly request target startup or start it afterwards, then return to
the saved definition and Start. Saving does not grant access, and deleting a definition
does not release a potentially shared port. Ordinary TCP needs no Ethernet assignment.
Startup and plugin restart load definitions and start nothing. **Start** explicitly resolves assigned serial ports, registers the
mappings and only then opens the transport; a registration failure opens nothing.
Stop a connection before saving a change; there is no live reconfiguration.
**Stop** terminates the runtime, which clears its platform bindings, claims, desires
and observations, but not definitions. To use both RS485 ports against each other,
start the server first, then the client.

```elixir
ModbusPlugin.save("server1", %{
  "role" => "server", "transport" => "rtu", "serial_port" => "ttyS3",
  "authorized" => true, "speed" => 9600, "parity" => "none", "stop_bits" => 1,
  "unit" => 1, "timeout" => 1000,
  "mappings" => [
    %{"id" => "holding0", "table" => "holding", "address" => 0, "initial" => 0},
    %{"id" => "coil0", "table" => "coil", "address" => 0, "initial" => false}
  ]
})
ModbusPlugin.start("server1")
ModbusPlugin.status()
ModbusPlugin.stop("server1")
```

## Desired state

Client outputs are repeatable setters only; there are no pulses, toggles,
increments or command journals. Each started client runs a linked
`NervesGateSDK.Output` runtime (`ModbusPlugin.Outputs`) that applies the newest
Desire as one setter, serialized with the connection's reads; queued hints are not
replayed as writes. A successful write reports `:applied`, a timeout `:unknown`
and any other error `{:failed, reason}`; both are retried after the poll interval
because these setters are repeatable. When linked readback disagrees with the last
written value, the output is applied again. A released or lost Desire holds the
last value (`on_release: :hold`): no physical write and no fallback value.

Failed reads publish `:invalid` (Modbus exception) or `:unknown` (timeout or
transport loss) with no value. The gateway's Status confirms an output only from
fresh readback received after the Desire changed, never from the write alone.

Manual desires from the page go through the supervised `ModbusPlugin.Command`
process, which holds the platform claim; UI processes never own desired state.

## RTU over RS485

1. Under Hardware, enable and assign `ttyS3` and/or `ttyS4` to `modbus_plugin`.
   Confirming changes stops BOTH affected plugins and all their connections/ports;
   checked cleanup precedes persistence and both plugins remain stopped.
2. Start the plugin. Save an RTU definition for an assigned port with supported
   speed (1200–115200), parity (none/even/odd) and stop bits (1/2); 8 data bits.
   Confirm authorization. Device paths are not accepted from forms/API callers.
3. Explicitly **Start**. One running connection per physical serial port; an
   unexpectedly dead RTU worker keeps its port reserved until the whole plugin is
   stopped, because its native handle cannot be verified as drained.

The EC100 uses automatic direction control. No guessed DE/RTS GPIOs.

TCP is unauthenticated/unencrypted and serial is a shared physical bus: use only
explicitly authorized equipment/networks. Real board electrical behavior, connector
mapping and PLC operation remain separately qualified activities.

## Tests

Run `mix test` here for validation, storage, admission and fail-closed behavior.
Without the platform, Start is refused before any socket or port opens. The real
platform + protocol flow (server, client, desire, feedback, reconciliation, loss)
runs in the QEMU `plugins` scenario over loopback TCP. RTU between the EC100 ports
requires separately authorized physical testing. See
[hardware](../../docs/hardware.md) and [development](../../docs/plugin-development.md).

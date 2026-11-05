# Raw Modbus TCP / RTU

This plugin owns Modbus connections and raw data—not equipment meaning.
Coils/discrete inputs are booleans; holding/input registers are unsigned 16-bit
words (0–65535). A consuming integration combines words, decodes numbers/text,
applies scaling/units and registers its own meaningful platform inputs/outputs.
There are no datatype mappings, templates, automatic endpoint registration or
desired-state control in this transport plugin.

Uses [yamodbus 0.1.0](https://github.com/tallakt/yamodbus), Apache-2.0 licensed,
bundled as private pure-Elixir code. Firmware supplies native `circuits_uart`
1.7.0, the SDK and LiveView; no device downloads or dependency resolution.

## Setup

1. Choose **Client**, **TCP**, the device IP/port (usually 502) and unit ID.
2. Add raw ranges with an ID, table, start address and count.
3. Save to SD, then explicitly Start. Refresh shows grouped raw observations.

TCP clients use normal gateway routing, with no LAN selector or exclusive
Ethernet assignment. TCP servers listen on all interfaces. Use trusted networks:
Modbus TCP has no authentication or encryption.

For RTU, choose the RS485 resource, baud/parity/stop bits (8 data bits), confirm
bus authorization, and save. **Assign port / enable access** opens gateway-owned
hardware review; assignment may stop the entire plugin and starts nothing
implicitly. Start checks the enabled assignment and device presence. One runtime
per serial port; unexpected death retains its reservation until whole-plugin
cleanup verifies closure. EC100 uses automatic direction control, not guessed
GPIOs. Physical bus/equipment qualification requires separate authorization.

## Definitions and bounds

```elixir
ModbusPlugin.save("inverter", %{
  "role" => "client", "transport" => "tcp",
  "host" => "192.0.2.10", "port" => 502, "unit" => 1,
  "interval" => 1000, "timeout" => 1000,
  "ranges" => [
    %{"id" => "words", "table" => "input", "address" => 33149, "count" => 2}
  ]
})
ModbusPlugin.start("inverter")
ModbusPlugin.status()
```

**Addresses are zero-based protocol addresses**, exactly the numbers on the wire.
Do not automatically subtract 30001/40001 from a vendor's documented addresses.

| Table | Read | Writable client range |
|---|---|---|
| `coil` | FC01, up to 2000 bits | FC05/15, up to 1968 bits |
| `discrete` | FC02, up to 2000 bits | Never |
| `holding` | FC03, up to 125 words | FC06/16, up to 123 words |
| `input` | FC04, up to 125 words | Never |

Each range is **one request**, not separately sampled words. Choose ranges that
are fully implemented by the device; normal polling does not speculate across
gaps or silently split a failed batch. A failed range returns no values and
invalid quality for exceptions, unknown quality for transport failures/timeouts.
Other ranges retain their own observations and timestamps.

`status/0` returns saved connections with their current `observations`, keyed by
range ID, e.g.:

```elixir
%{values: [65535, 65436], quality: :good, error: nil, observed_at: "..."}
```

The next layer consumes the whole observation and checks its quality and freshness
before interpretation. It is responsible for word order, signedness, floats,
strings, scaling, units, device models (including SunSpec/Solis) and SDK endpoints.
No generic transformation framework is introduced here.

At most 16 connections, 64 non-overlapping ranges per connection and 4096 total
addresses per definition. IDs match `[a-z][a-z0-9_]{0,31}`. Units are 1–247;
addresses 0–65535; timeout 100–5000 ms; client interval 100–60000 ms. Empty client
ranges permit discovery-only definitions; normal Start refuses `:no_ranges`.

Servers use the same range coordinates, with optional `initial` raw lists;
defaults are zero/false. Remote writes affect only mapped coil/holding spans,
atomically. `ModbusPlugin.Server.put(connection, range, values)` explicitly changes
a whole local range, including input/discrete tables. Server identification
reports this plugin, not attached equipment.

## Explicit raw writes

A client range must explicitly have `"writable" => true`. Then:

```elixir
ModbusPlugin.write("controller", "setpoints", [0, 42])
```

The list must cover the entire range, with raw integers or booleans. One call
sends one FC05/06/15/16 operation, serialized with reads. At most one write is
accepted at a time; another is refused as busy. **No retry, desire, reapplication
or inferred readback confirmation.** Timeout/caller exit may leave an unknown
outcome; never blindly replay it. A write response is not physical equipment
confirmation. Cached observations of that range are invalidated until reread.
The next layer owns application-specific write admission and control semantics.

## Save and lifecycle

Save and plugin startup never communicate. Stop before changing a definition.
Stop closes transports and clears in-memory observations, not saved definitions.
Managed activation membership is checked before controller Start/discovery;
RTU additionally requires the assigned hardware resource.

Configuration is version-scoped SDK storage on SD, with no internal-storage
fallback or automatic migration. A new version starts empty, leaving older terms
and endpoint history untouched. Unsupported saved schemas, unavailable storage
and uncertain commits fail closed without rewriting state. Validation names the
invalid connection field or range. Typed mapping fields are rejected, not ignored.

## Optional read-only discovery

Hidden under **Advanced** for a stopped client. Choose unit IDs, table, address
and count. Protocol identification and FC01–04 probes precede the scan. It keeps
raw evidence in memory until Stop; it never registers endpoints, saves ranges,
sends writes or guesses device semantics. Reads themselves may affect counters;
check the manual and avoid other masters.

The API accepts `units` (1–16 IDs), `ranges` (up to 8, totalling 4096 addresses),
`budget` (1–1000 requests, default 200), `delay` (0–5000 ms, default 50) and
`identify` (default true). Illegal-address scans bisect down to individual points,
within the same budget. Identification continuation is budgeted too. At most 4096
successful observations are retained; exhaustion is explicit. Finish closes the
transport, keeping results until Stop. The UI shows up to 256 observations;
`status/0` exposes the bounded complete result. Polling resumes only after Stop
and explicit Start.

## Validation

From the repository root: `mix plugin.test plugins/modbus` and `mix check`.
Tests exercise raw validation, persistence, admission, rendered forms, real TCP
polling/writes, write uncertainty, discovery budgets, pacing and gaps. The QEMU
`plugins` scenario covers real managed activation and storage, all four tables,
grouped raw I/O and discovery without platform endpoint creation. Runtime QEMU
and physical validation are separate from host checks and firmware builds.

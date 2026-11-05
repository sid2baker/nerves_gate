# Modbus TCP / RTU plugin

Firmware-selected Modbus clients and servers using
[yamodbus 0.1.0](https://github.com/tallakt/yamodbus), Apache-2.0 licensed.
Private pure-Elixir yamodbus code is bundled with it. Native `circuits_uart`
1.7.0, the SDK and LiveView are supplied by firmware, not bundled.

## Data model

Each saved connection has an ID, role, transport, unit (1–247), timeout
(100–5000 ms) and up to 64 mappings. Servers need at least one; a client
may save an empty list for discovery only (normal Start refuses `:no_mappings`).
There may be 16 definitions. IDs are lowercase,
letter-led `[a-z0-9_]`, at most 32 characters. Mapping IDs name stable equipment
meaning and become `modbus_plugin.<connection>.<mapping>` platform endpoints.
The platform retains definitions after deletion; changed meaning needs a new ID.

**Addresses are zero-based protocol addresses, 0–65535**, the number sent on the
wire. Do not enter a vendor's `30001`/`40001` register notation without converting
it according to the device manual. Some vendors, including the Solis template,
already document protocol addresses; do not subtract a base automatically.

| Table | Read | Client writes |
|---|---|---|
| `coil` | FC01 | FC05 |
| `discrete` | FC02 | Never |
| `holding` | FC03 | FC06 (one register), FC16 (multiple) |
| `input` | FC04 | Never |

Client mappings have `access: "read"` (default) or `"write"`. Server mappings
have no access field: every point is a local platform input, remotely writable
only in coil/holding tables. Server mappings may not overlap; client read views
may overlap but two writers may not own the same address. A server refuses
unmapped addresses, another unit and undecodable writes without changing its map.
TCP servers listen on the configured port on all addresses. Servers also answer
FC43/14 and FC17 with the plugin identity, not physical equipment identity.

```json
[
  {"id":"battery_soc","table":"input","address":33139,"access":"read","type":"u16","unit":"%"},
  {"id":"battery_power","table":"input","address":33149,"access":"read","type":"s32","scale":1,"unit":"W","word_order":"high_first"}
]
```

| Type | Width | Platform value |
|---|---|---|
| `bool` | 1 bit-table point or 1 register | boolean |
| `u16`, `s16` | 1 register | integer, or float with a float scale |
| `u32`, `s32` | 2 registers | integer, or float with a float scale |
| `float32` | 2 registers | IEEE-754 float |
| `ascii` | `length` registers (1–123) | string |

Coils/discrete inputs accept only `bool` (their default); other tables default
to `u16`. A register `bool` means non-zero, or selects `bit: 0..15` on a client
read. Bit views are read-only, not unsafe whole-word writers.

Numeric mappings accept `scale` (default 1, non-zero, absolute value 0.000001 to
1000000). Published value is raw × scale. Integer types with an integer scale
remain integers; a floating scale publishes a float rounded to the scale's
decimal precision. IEEE floats publish their shortest float32-round-trip decimal
before scaling. NaN/infinity and invalid text publish invalid quality, never a
fabricated value. `unit` is optional, up to 32 UTF-8 bytes.

32-bit types accept `word_order: "high_first"` (default) or `"low_first"`.
Bytes within a register are high-byte first. ASCII ends at the first NUL and
trims trailing spaces. Writes are zero-padded and must fit and read back exactly.
Numeric writes must likewise be representable and read back exactly; e.g. 1.23
cannot be written with scale 0.1. Invalid values are refused before sending.

Servers accept `initial` in published units (default zero/false/empty string).
`ModbusPlugin.Server.put(connection, mapping, value)` sets a local typed value,
including input registers and discrete inputs, and publishes it.

## Polling and desired state

Clients poll every `interval` (100–60000 ms). A plan merges adjacent or
overlapping reads of one table into FC01/02 batches of up to 2000 bits or FC03/04
batches of up to 125 registers. `max_gap` (0–100, default 0) explicitly permits
reading gaps; **many devices refuse any batch touching an unmapped address**.
One failed batch invalidates all its mappings. No automatic speculative polling
fallback conceals a bad mapping.

A write mapping can link `feedback` to a read mapping of the same platform value
type. This is readback evidence, not proof of a physical equipment condition.
Output types, units and bounds derive from the mapping. The actual managed
connection owns its inputs, transport and linked `NervesGateSDK.Output` worker;
the supervised `ModbusPlugin.Command` owns manual output claims, never a UI PID.

Outputs are repeatable setters only, not pulses, toggles or command registers.
Setters and batched reads share one serialized transport. The output worker
re-reads the newest Desire before applying; a successful write reports applied,
a timeout unknown and another error failed. Failed/uncertain repeatable setters
are reapplied after the interval, and disagreeing readback requests reapplication.
Releasing a Desire holds the last value: it performs no write. Status confirms a
Desire only from fresh readback after the Desire changed, not a write response.
Read exceptions publish invalid quality; transport loss/timeouts publish unknown,
without retaining a fabricated successful value.

## Save, Start, Stop and storage

Save never communicates. Startup/restart only restore definitions and start
nothing. Start registers the mapped endpoints and opens the transport; a failed
registration opens nothing. Stop before saving changes. Stop clears runtime
bindings, claims, desires and observations, not endpoint history.

Definitions are this plugin version's SDK storage configuration term. A new
version starts with no definitions; old versions' terms stay on the SD card and
are not imported. There are no legacy schema aliases: `direction` is rejected;
use `access` in new drafts. Missing SD storage refuses saving, with no `/data`
fallback. Unsupported saved terms or uncertain commits fail closed without
rewriting state. Validation errors identify fields or individual mappings:

```elixir
{:error, {:invalid_mapping, "battery_power", {:invalid_type, "s64"}}}
{:error, {:invalid_mapping, "soc", {:address_out_of_range, 70000}}}
{:error, {:invalid_field, "unit", 0}}
```

For RTU, save a stopped definition with `serial_port` (resource ID, never a
path), `authorized: true`, speed 1200–115200, parity none/even/odd, stop bits 1/2
and 8 data bits. Use **Assign port / enable access** to review its exclusive
hardware assignment. This may stop the whole plugin; nothing restarts
automatically. Start resolves the currently enabled, assigned RS485 resource.
One runtime per serial port; an unexpected RTU death retains its reservation
until the whole plugin is stopped and cleanup verified. EC100 uses automatic
direction control, not guessed DE/RTS pins. TCP needs no Ethernet assignment.

## Read-only discovery

Discovery is **separate from normal mappings** and explicitly runs instead of a
stopped client on its transport. It never registers endpoints or sends a write
function code. It identifies devices using FC43/14 basic objects (including
budgeted continuation) and FC17, probes FC01/02/03/04 at address 0, and scans
operator-selected ranges. A probe exception is raw evidence, not proof that a
table is absent: address 0 may simply be unmapped.

```elixir
ModbusPlugin.discover("inverter", %{
  "units" => [1],
  "ranges" => [%{"table" => "input", "address" => 33133, "count" => 18}],
  "budget" => 200, "delay" => 50, "sunspec" => false
})
ModbusPlugin.status()
ModbusPlugin.stop("inverter")
```

Limits: 16 distinct units in 1–247; 8 ranges totalling at most 4096 addresses;
1–1000 requests (default 200); 0–5000 ms between requests (default 50). Every
probe, identification page and retry-free scan request counts. Ranges use
protocol-sized chunks; illegal-address chunks split down to single addresses,
within the same budget. The survey stores at most 4096 successful observations.
Budget/evidence exhaustion stops it visibly with remaining work; failures retain
their unit, table, range, error and UTC observation time. Successful evidence is:

```elixir
%{unit: 1, table: :input, address: 33139, raw: 80, hex: "0050", observed_at: "..."}
```

Read-only does **not** mean harmless: some equipment resets counters on reads,
and a scanner consumes shared bus time. Check the manual, authorize the selected
units/ranges and avoid other masters. No broadcast unit 0 or automatic background
scans. Stop cancels the survey; completion closes the transport, keeping only
in-memory results until Stop/plugin shutdown. The UI displays up to 256 results;
the status API exposes the entire bounded result.

**Promote to draft** copies one observed address and its unit into the editor.
The operator still supplies ID, datatype, scale and meaning, stops discovery and
saves explicitly. A value resembling a percentage never becomes SOC automatically.
Promotion never changes saved mappings or starts normal polling.

## Optional profiles and SunSpec

**Load Solis hybrid template** replaces only the mapping draft. It covers PV1/2
voltage/current, total PV power, temperature, battery SOC and battery power.
Register facts are cross-checked against the [Solis integration](https://github.com/Pho3niX90/solis_modbus/blob/master/custom_components/solis_modbus/sensor_data/hybrid_sensors.py)
and [evcc Solis hybrid definition](https://github.com/evcc-io/evcc/blob/master/templates/definition/meter/solis-hybrid.yaml).
These are a starting point, **not qualification of every S6/RHI model or firmware**;
verify the manufacturer's register map and battery-power sign convention. The
template preserves raw signed battery power (no inferred charge/discharge sign).

With `sunspec: true`, discovery looks for the `SunS` marker in holding registers
at protocol addresses 0, 40000 and 50000. It walks actual model headers until
0xFFFF, address bounds or 64 models, under the same request budget. Unknown
models remain IDs, lengths and addresses. For discovered common model 1, the UI
can load manufacturer/model/firmware strings into a draft. It does not guess
vendor data or decode arbitrary inverter models/scale-factor dependencies.
Profiles are plain mapping data, not a second transport or automatic activation
framework. No unsupported Victron map is invented.

## Validation

From the repository root: `mix plugin.test plugins/modbus` or `mix check`.
Tests cover codecs, validation, plans, storage/admission, UI drafts and real TCP
discovery with budgets, gaps, pacing, pagination and SunSpec. No fake SDK backend.
The QEMU `plugins` scenario exercises real platform ownership, all four tables,
multi-register writes, typed feedback, discovery and explicit polling resumption.
Physical RTU/equipment qualification requires separate authorization.
See [hardware](../../docs/hardware.md) and [plugin development](../../docs/plugin-development.md).

# Changelog

## Unreleased

### Breaking changes

- 0.5.0-dev.2 uses typed mappings with `access: read|write` instead of `direction`; legacy fields are rejected with mapping-specific errors. Saved configuration remains version-scoped, with no import or migration. Select and configure the new version explicitly.

### Added

- Clients and servers support all four Modbus tables, signed/unsigned 16/32-bit numbers, float32, strings, scaled units, word order and read-only register-bit views. Multi-register setters use FC16; unrepresentable writes are refused before sending.
- Clients batch adjacent/overlapping reads within protocol limits, with an explicit optional gap allowance. Validation identifies the connection field or mapping and exact refusal reason.
- Operator-started read-only discovery identifies devices, probes units/tables and scans bounded address ranges with request budgets and pacing. Raw timestamped evidence stays in memory and can be promoted into mapping drafts without registration or automatic saves.
- Optional Solis hybrid telemetry drafts and SunSpec marker/model-header discovery, with common-model string drafts for actually discovered models. No vendor meaning is inferred from raw values.
- Modbus TCP/RTU server exposing exactly its mapped points, with explicit local value changes.
- Client desired-state reconciliation: latest desire before each setter, rewrite on feedback mismatch, no write for a nil desire. Failed reads publish invalid/unknown without values.
- Supervised manual writer (`ModbusPlugin.Command`) holding platform claims for the page.

### Changed

- Version 0.4.3 requires SDK 0.2.0-dev.6, declares `:rs485` and lists board-defined ports and labels. Saved RTU definitions accept any well-formed resource ID; Start checks enabled RS485 ownership. Assignment links use `/hardware/:id`. No port is selected automatically; older version-scoped configuration is preserved, not imported.

- Version 0.4.2 offers RS485 choices in the connection form and links saved, unassigned drafts to gateway-owned assignment review. Start remains explicit and requires current enabled ownership. Requires SDK 0.2.0-dev.5; older version-scoped configuration is preserved, not imported.

- Version 0.4.0 applies outputs through the SDK's `NervesGateSDK.Output` runtime: newest Desire only, Apply outcomes under the current claim epoch, `:hold` release behaviour, retry after the poll interval for failed or uncertain repeatable setters, and reapplication when readback disagrees. Linked feedback inputs are declared as readback evidence. Requires SDK `~> 0.2.0-dev.3` and firmware with output Status; definitions saved by 0.3.0 stay on the card and are not loaded.

- Version 0.3.0 replaces volatile read-only polling with saved client and server definitions, persisted as the plugin version's `NervesGateSDK.Storage` configuration term. `configure/connect/disconnect` are replaced by `save/start/stop/delete`; the read-only FC3/FC4 block definition is not supported and nothing is migrated. Save and plugin startup never communicate.
- Mapped holding registers and coils are registered as platform inputs and repeatable outputs through `NervesGateSDK.IO`, with optional linked feedback, by the runtime process that owns the transport.
- RTU speed, parity and stop bits are configurable (8 data bits).

### Fixed

- The largest finite float32 values use the same shortest-decimal bounds for readback and writing. Discovery reports evidence exhaustion even when its final response exceeds the remaining result space.

### Compatibility

- Version 0.4.1 gives the reproducibly packaged artifact a new immutable identity. Existing 0.4.0 selections and configuration remain unchanged; selecting 0.4.1 is explicit and its version-scoped configuration starts empty.
- Requires firmware with the `NervesGate.IO` domain and plugin configuration storage, and SDK `~> 0.2.0-dev.2`.
- Version 0.2.4 is rebuilt against the plugin-terminology SDK. Saved 0.2.3 artifacts and plugin selections remain unchanged.
- Version 0.2.3 gives the rebuilt artifact a new immutable identity. Saved 0.2.2 artifacts and plugin selections remain unchanged.

## 0.2.2 - 2026-10-27

### Fixed

- Keep RTU cleanup fenced when a connection worker exits immediately after starting, without crashing the controller during monitor registration.

## 0.2.1 - 2026-10-27

### Compatibility

- Rebuilt for the Hardware inventory domain and administrative schema 11.

## 0.2.0 - 2026-10-27

### Added

- Read-only RTU polling over explicitly assigned RS485 ports using firmware-provided circuits_uart 1.7.0, automatic-direction 9600 8N1 and explicit operator authorization.

## 0.1.0 - 2026-10-26

### Added

- Explicitly configured read-only Modbus TCP polling using yamodbus, with volatile configuration and supervised connection cleanup.

# Changelog

## Unreleased

### Changed

- Version 0.4.0 applies outputs through the SDK's `NervesGateSDK.Output` runtime: newest Desire only, Apply outcomes under the current claim epoch, `:hold` release behaviour, retry after the poll interval for failed or uncertain repeatable setters, and reapplication when readback disagrees. Linked feedback inputs are declared as readback evidence. Requires SDK `~> 0.2.0-dev.3` and firmware with output Status; definitions saved by 0.3.0 stay on the card and are not loaded.

- Version 0.3.0 replaces volatile read-only polling with saved client and server definitions, persisted as the plugin version's `NervesGateSDK.Storage` configuration term. `configure/connect/disconnect` are replaced by `save/start/stop/delete`; the read-only FC3/FC4 block definition is not supported and nothing is migrated. Save and plugin startup never communicate.
- Mapped holding registers and coils are registered as platform inputs and repeatable outputs through `NervesGateSDK.IO`, with optional linked feedback, by the runtime process that owns the transport.
- RTU speed, parity and stop bits are configurable (8 data bits).

### Added

- Modbus TCP/RTU server exposing exactly its mapped points, with explicit local value changes.
- Client desired-state reconciliation: latest desire before each setter, rewrite on feedback mismatch, no write for a nil desire. Failed reads publish invalid/unknown without values.
- Supervised manual writer (`ModbusPlugin.Command`) holding platform claims for the page.

### Compatibility

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

# Changelog

## Unreleased

### Breaking changes

- 0.6.0-dev.1 replaces typed mappings with raw `ranges` (`id`, `table`, `address`, `count`). It no longer converts values, registers platform inputs/outputs, claims desires, retries writes or supplies device templates. The consuming integration owns interpretation and desired-state control.
- Definitions stay version-scoped. Existing configurations and endpoint history are left untouched, never imported or rewritten. Unsupported schemas and fields are rejected explicitly.

### Added

- Each client range returns one coherent observation of booleans or unsigned 16-bit words, with quality, error and timestamp. Explicit whole-range writes serialize with polling; timeouts have an unknown outcome and are never retried automatically.
- Client ranges are read-only unless marked writable. Multi-register writes use FC16, multiple coils FC15; limits and raw values are validated before sending. Servers expose bounded raw maps of all four tables.
- A range editor replaces mapping JSON. Read-only discovery is a separate advanced control with bounded requests, pacing and raw in-memory results; it never creates ranges or endpoints.

### Fixed

- 0.6.0-dev.2 ignores LiveView unused-field metadata when saving forms. Each raw range has a right-aligned Remove button; adding after removal chooses an unused default range ID.

### Compatibility

- Requires SDK `~> 0.2.0-dev.6`, board-declared RS485 assignments for RTU, and SD-backed plugin configuration storage. Ordinary TCP uses normal gateway routing without Ethernet assignment.

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

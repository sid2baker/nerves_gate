# Changelog

## Unreleased

### Compatibility

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

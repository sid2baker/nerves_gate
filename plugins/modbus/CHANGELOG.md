# Changelog

## Unreleased

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

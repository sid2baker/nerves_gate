# Changelog

## Unreleased

- Match the stock agent's 25 ms discovery/configuration command spacing.
  Reply deadlines and fail-closed startup remain unchanged. Experimental artifact
  0.1.1-dev.1 still fails warm bus restart with a card-2 discovery timeout; this is
  not a validated fix. Registered 0.1.0 artifacts are never replaced.

- Initial experimental SDK-managed expansion-bus plugin: explicit assignment,
  reset/discovery/start, captured D1600/D0016N layouts, platform inputs and outputs
  with echo evidence, checked stop and no automatic activation/reconnect.
- Uses firmware-supplied circuits_uart 1.7.0 and circuits_gpio 2.3.1; requires
  SDK 0.2.0-dev.8 firmware. Electrical qualification remains outstanding.

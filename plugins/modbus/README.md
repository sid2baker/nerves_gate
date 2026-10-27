# Modbus TCP / RTU plugin

Firmware-selected read-only Modbus polling using
[yamodbus 0.1.0](https://github.com/tallakt/yamodbus), Apache-2.0 licensed.
The plugin version is 0.2.0. Private pure-Elixir yamodbus code is bundled with it.
Native `circuits_uart` 1.7.0 is supplied by firmware, not bundled in the plugin;
SDK/LiveView are shared platform libraries too.

## TCP

Start `modbus_plugin` under **Plugins**, then open its page. Select TCP and save
host, port, unit ID, register table, zero-based address/count, interval and timeout.
Saving opens no connection. **Connect and poll** explicitly starts a supervised
client. **Disconnect** closes it and stops polling/reconnects. TCP uses ordinary
sockets without physical-port assignment and never reconfigures gateway networking.

## RTU over RS485

1. Under Hardware, enable and assign `ttyS3` and/or `ttyS4` to `modbus_plugin`.
   Confirming changes stops BOTH affected plugins and all their connections/ports;
   checked cleanup precedes persistence and both plugins remain stopped.
2. Start the plugin. Select RTU and an assigned, enabled, detected port.
3. Configure unit/register reads and confirm authorization and that no other master
   is active. Device paths are not accepted from forms/API callers.
4. Save, then explicitly **Connect and poll**. No traffic is sent by viewing or saving.

The initial EC100 profile is automatic-direction **9600 8N1**. No guessed DE/RTS
GPIOs or unqualified profiles. One connection per physical serial port is admitted;
assign both ports to operate independent workers concurrently. The controller queries
the actual managed caller's assignments before opening through yamodbus. The plugin
owns the client and UART worker/native handle, not a platform byte-stream proxy.

```elixir
ModbusPlugin.configure("meter", %{
  "transport" => "rtu", "serial_port" => "ttyS3", "authorized" => true,
  "unit" => 1, "table" => "holding", "address" => 0, "count" => 2,
  "interval" => 1000, "timeout" => 1000
})
ModbusPlugin.connect("meter")
ModbusPlugin.status()
ModbusPlugin.disconnect("meter")
```

## Limits and cleanup

Up to 16 configurations. FC3/FC4, units 1–247, zero-based addresses, 1–125 raw
16-bit words without crossing address 65535, intervals 100–60000 ms and timeouts
100–5000 ms. No register writes/broadcasts, scanning, ASCII, TLS UI or persistence.
Address/float interpretation belongs to equipment-specific logic.

At most one poll is in flight per connection. After explicit connection, yamodbus
may reconnect its transport; only read requests are sent. Errors clear displayed
values and retain the last-success timestamp. Disconnect/plugin stop closes clients;
a crashed connection is not automatically restarted by the plugin supervisor.
Restart clears configuration and never connects automatically. Assignments persist,
not active equipment sessions. No SD is required for code or volatile configuration.

TCP is unauthenticated/unencrypted and serial is a shared physical bus: use only
explicitly authorized equipment/networks. The plugin cannot detect every competing
external master. Real board electrical behavior, connector mapping and PLC operation
remain separately qualified activities, not consequences of passing host tests.

## Tests

Run `mix test` here. TCP tests use a disposable supervised loopback peer. RTU tests
require `socat` and use disposable PTYs with the actual yamodbus/circuits_uart code,
checking wire CRCs, exception/timeout handling and close/reopen. No test attaches to
physical ports. See [hardware](../../docs/hardware.md) and
[development](../../docs/app-development.md).

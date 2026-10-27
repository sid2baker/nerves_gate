# Modbus TCP plugin

Firmware-selected read-only Modbus TCP polling with
[yamodbus 0.1.0](https://github.com/tallakt/yamodbus), Apache-2.0 licensed.
`yamodbus` is this plugin's private pure-Elixir dependency; its optional native
serial dependency is not included. Shared SDK/LiveView libraries come from firmware.

Start `modbus_plugin` under **Plugins**, then open its page. Save a device's host,
TCP port, unit ID, register table, zero-based address/count, poll interval and timeout.
Saving configuration opens no connection. **Connect and poll** explicitly starts a
supervised client. **Disconnect** closes it and stops polling/reconnects.

Up to 16 device configurations are supported. Reads use FC3 holding or FC4 input
registers (1–125 words, without crossing address 65535), unit IDs 1–247, intervals
100–60000 ms and request timeouts 100–5000 ms. Values are raw 16-bit words, not
application-specific floats or 40001-style addresses. No register writes, serial
access, automatic discovery, TLS configuration or persistence is exposed here.

The client has at most one poll in flight. After an explicit connection,
yamodbus reconnects its TCP transport after failures; only read requests are sent.
Timeouts/errors clear displayed values and retain the timestamp of the last success.
Disconnect or plugin stop terminates clients. A crashed connection is not restarted
automatically by the plugin supervisor. Restart clears all configurations and opens
no connections. Code/configuration does not require SD.

```elixir
ModbusPlugin.configure("meter", %{
  "host" => "192.168.50.10", "port" => 502, "unit" => 1,
  "table" => "holding", "address" => 0, "count" => 2,
  "interval" => 1000, "timeout" => 1000
})
ModbusPlugin.connect("meter")
ModbusPlugin.status()
ModbusPlugin.disconnect("meter")
```

These are ordinary TCP connections, not exclusive Ethernet claims. The plugin does
not configure gateway networking. Modbus TCP itself is unauthenticated/unencrypted;
use only explicitly chosen trusted equipment networks. Vendor-equipment qualification
and application-specific register interpretation remain the operator/plugin's job.

Run `mix test` in this directory for configuration/UI tests and real yamodbus client
traffic against a disposable supervised loopback TCP peer. No physical equipment is
contacted. See [development](../../docs/app-development.md).

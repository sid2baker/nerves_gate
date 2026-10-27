defmodule Workbench.Skill.DeviceInspection do
  use Pi.Skill.Script

  skill do
    name("device-inspection")

    description(
      "Read identity, status, plugins, hardware and recent logs from a running Nerves Gate dev device over Erlang distribution."
    )

    markdown("""
    # Inspect a development device

    Use `Workbench.DeviceInspection` through `elixir_eval` in the project target.
    This host-only API connects with the fixed development cookie automatically.
    No Mix task, Workbench session or application startup is needed.

    ```elixir
    target = :\"nerves_gate@100.120.69.127\"
    Workbench.DeviceInspection.identity(target)
    Workbench.DeviceInspection.plugins(target)
    Workbench.DeviceInspection.hardware(target)
    Workbench.DeviceInspection.status(target)
    Workbench.DeviceInspection.logs(target, limit: 50, level: :warning)
    ```

    Every call returns `{:ok, value}` or `{:error, reason}`. Strings such as
    `"nerves_gate@100.120.69.127"` work too. Connection attempts wait up to three
    seconds; each RPC waits up to five seconds. An existing distribution node is
    reused; otherwise a local inspection node is started. `connect/1` is available
    for checking connectivity explicitly.

    Read identity first and confirm the intended device. These are trusted dev
    devices, not a production authentication mechanism. Never print cookies.
    Read `plugins/1` separately: administrative status does not include the full
    plugin lifecycle state. `hardware/1` reads public inventory/assignments, not
    caller-owned SDK resources; it never opens equipment handles.

    Logs return the latest `limit` entries (1–100), filtered by minimum `level`.
    Default level is `:warning`; use `:info` or `:debug` when necessary. Messages
    are trimmed to 2 KB each and 16 KB total. Session/parameter lines, credential
    lines, URLs and crash-state dumps are removed before returning results.
    Returned metadata is limited to index, timestamp and level. Device timestamps
    may differ from workstation time. Do not bypass sanitation by dumping raw
    RingLogger entries or complete process state into model context.

    This skill is read-only. It does not fix software, start/stop plugins, assign
    hardware, connect equipment, reboot or update firmware. Report errors rather
    than retrying mutations. Firmware updates remain in the existing reviewed
    Workbench workflow. Do not expose a generic remote RPC/eval helper.
    """)
  end

  def apis do
    [
      Pi.Plugin.API.new(
        name: :device_inspection,
        module: Workbench.DeviceInspection,
        alias: :DeviceInspection,
        description: "Read-only dev-device inspection using the fixed development cookie.",
        examples: ["Workbench.DeviceInspection.logs(\"nerves_gate@100.120.69.127\", limit: 20)"]
      )
    ]
  end
end

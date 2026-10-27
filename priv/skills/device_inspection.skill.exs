defmodule Workbench.Skill.DeviceInspection do
  use Pi.Skill.Script

  skill do
    name("device-inspection")

    description("Inspect physical and simulated gateways connected to the attached Workbench.")

    markdown("""
    # Inspect connected development gateways

    First attach using the `dev-environment` skill. Run these calls in
    `elixir_eval` with target `runtime`, not project:

    ```elixir
    Workbench.DeviceInspection.devices()
    Workbench.DeviceInspection.identity(target)
    Workbench.DeviceInspection.plugins(target)
    Workbench.DeviceInspection.hardware(target)
    Workbench.DeviceInspection.status(target)
    Workbench.DeviceInspection.logs(target, limit: 50, level: :warning)
    ```

    Choose an exact node from devices/0; never choose silently when several are
    connected. Workbench owns discovery, the dev cookie and reconnects. Inspection
    does not start its own node, connect arbitrary targets or open hardware.
    Domain reads return {:ok, value} or {:error, reason} with five-second RPC bounds.
    Logs are capped at 100 entries, 2 KB per message and 16 KB total, with session,
    credential and crash-state dumps removed. Do not bypass sanitation with raw
    RingLogger or process-state dumps. Offline targets return an error.
    No plugin starts, assignments, equipment connections or firmware updates occur.
    """)
  end

  def apis,
    do: [
      Pi.Plugin.API.new(
        name: :device_inspection,
        module: Workbench.DeviceInspection,
        alias: :DeviceInspection,
        description: "Semantic read-only inspection from the attached Workbench runtime."
      )
    ]
end

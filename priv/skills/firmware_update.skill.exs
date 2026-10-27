defmodule Workbench.Skill.FirmwareUpdate do
  use Pi.Skill.Script

  skill do
    name("firmware-update")

    description(
      "Flash explicitly authorized physical EC100 firmware through the running Workbench, with plugin compatibility preflight and verified reboot."
    )

    markdown("""
    # Update physical firmware

    Only call this after the user explicitly authorizes flashing the target.
    Use the compiled project API through `elixir_eval` in the project target:

    ```elixir
    Workbench.DeviceUpdate.update(
      "nerves-gate.tail40465.ts.net",
      "firmware/_build/ec100_dev/nerves/images/nerves_gate.fw"
    )
    ```

    The user must have `mix dev` running. The firmware must already be built.
    This helper uses the existing Workbench review/confirm operation queue and
    strict authenticated SSH, not distribution or a second flashing implementation.
    `mycookie` belongs to the separate dev inspection skill, not firmware upload.

    One call checks device identity, reads plugin inventory from the exact image,
    rejects changed artifacts under saved versions, reviews and confirms the exact
    image, uploads once, verifies the new healthy boot, and checks plugin management.
    It returns `{:ok, summary}` or `{:error, message}`. Allow up to six minutes.
    Summaries report active/available plugin versions; selection and startup remain
    explicit operator actions. No build, version bump, metadata erasure, hardware
    assignment, plugin start or equipment connection is performed automatically.

    If there is an error or timeout, inspect the current Workbench operation and
    device state. Never automatically repeat the call: an update may have been
    accepted even if its response or postcheck was lost. Do not stop/restart the
    user's Workbench, bypass admission, or flash from a temporary shell script.
    """)
  end

  def apis do
    [
      Pi.Plugin.API.new(
        name: :device_update,
        module: Workbench.DeviceUpdate,
        alias: :DeviceUpdate,
        description: "One explicitly authorized firmware update through Workbench."
      )
    ]
  end
end

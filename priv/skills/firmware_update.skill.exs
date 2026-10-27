defmodule Workbench.Skill.FirmwareUpdate do
  use Pi.Skill.Script

  skill do
    name("firmware-update")

    description(
      "Review and apply explicitly authorized physical EC100 firmware through the attached Workbench."
    )

    markdown("""
    # Update physical firmware

    Only after the user explicitly authorizes flashing the target. Attach with
    `dev-environment`, then in `elixir_eval` with target `runtime`:

    ```elixir
    {:ok, gateway} = Workbench.Gateways.fetch(:"nerves_gate@100.120.69.127")
    :ok = Workbench.Jobs.review_firmware(gateway.node, "firmware/_build/ec100_dev/nerves/images/nerves_gate.fw")
    Workbench.Jobs.snapshot() # wait for :awaiting_confirmation; show review to user
    ```

    Only after the user confirms that exact review, use its token and address:

    ```elixir
    %{status: :awaiting_confirmation, review: review} = Workbench.Jobs.snapshot()
    :ok = Workbench.Jobs.confirm_firmware(review.token, review.address)
    Workbench.Jobs.snapshot() # observe progress and final outcome
    ```

    Prefer the gateway page's review/confirm UI when the user is present; it is the
    same code. Review checks identity, health and plugin artifacts over distribution
    and the exact image; update uploads once over verified SSH and waits up to three
    minutes for a healthy new boot of the same serial. Jobs consumes each review
    once and publishes progress. Do not call low-level update helpers directly.

    Never repeat an update after an error or timeout: the device may have accepted
    it. Inspect with `device-inspection` instead. No build, version bump, plugin
    selection/start or metadata change happens here.
    """)
  end

  def apis do
    [
      Pi.Plugin.API.new(
        name: :firmware_update,
        module: Workbench.Jobs,
        alias: :Jobs,
        description: "Reviewed physical firmware update."
      )
    ]
  end
end

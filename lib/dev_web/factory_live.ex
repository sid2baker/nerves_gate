defmodule DevWeb.FactoryLive do
  @moduledoc "Initial USB provisioning, separate from routine SSH updates. Mounting never probes USB."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import DevWeb.Components
  import DevWeb.WorkbenchLive, only: [command: 2]

  def mount(_, _, socket), do: {:ok, assign(socket, :images, Dev.Builds.images())}

  def handle_event("refresh_images", _, socket),
    do: {:noreply, assign(socket, :images, Dev.Builds.images())}

  def handle_event("review_factory", params, socket),
    do: command(socket, Dev.Workbench.review_factory(params))

  def handle_event("confirm_factory", params, socket),
    do:
      command(
        socket,
        Dev.Workbench.confirm_factory(
          params["review_id"],
          params["confirmation"],
          params["identified"]
        )
      )

  def render(assigns) do
    assigns = assign(assigns, :review, factory_review(assigns.operation))

    ~H"""
    <main class="ui-main ui-stack bench" id="factory-page">
      <.back_link navigate="/firmware">Firmware</.back_link>
      <.page_header
        eyebrow="Physical EC100 · initial installation"
        title="Factory provisioning"
        description="Replace factory firmware over USB MASKROM. This is not a routine SSH update."
      />
      <.notice tone="warning" id="factory-warning">
        <p>
          <strong>Destructive: replaces the bootloader, partition layout, firmware and application data.</strong>
        </p>
        <p>
          Connect exactly one EC100 to the workstation running mix dev, using its Type-C
          download port, and put it in MASKROM mode. The FTDI serial console cannot flash it.
          Keep stable power connected and follow the board's watchdog/download-jumper instructions.
        </p>
        <p>
          USB identifies an RK3506, not a verified EC100 serial number. You must physically
          identify the board. Do not unplug, replace it, or connect another Rockchip device during review/install.
        </p>
      </.notice>
      <.panel title="Prepare and review" icon="port">
        <p>
          Build EC100 firmware first. Review verifies the image and boot artifacts, loads a temporary
          USB transport into RAM, reads eMMC capacity and checks backup disk space. Review writes nothing to eMMC.
        </p>
        <form id="review-factory" phx-submit="review_factory" class="ui-stack">
          <label for="factory-image">EC100 firmware</label>
          <select
            id="factory-image"
            name="firmware"
            required
            disabled={@images == [] or @operation.status == :running}
          >
            <option :for={image <- @images} value={image.path}>
              {image.version} · {image.build}
            </option>
          </select>
          <label for="factory-access">USB permissions</label>
          <select id="factory-access" name="sudo" disabled={@operation.status == :running}>
            <option value="false">Direct USB access (udev permissions)</option>
            <option value="true">Noninteractive sudo (-n)</option>
          </select>
          <p class="ui-help">
            Install rkdeveloptool on the workbench host. For sudo access, authorize it in a terminal
            first (sudo -v); the workbench never prompts for or stores your password.
          </p>
          <div class="ui-actions">
            <.button type="submit" disabled={@images == [] or @operation.status == :running}>
              Load RAM transport and review
            </.button>
            <.button type="button" phx-click="refresh_images" variant="secondary">Refresh firmware list</.button>
          </div>
        </form>
      </.panel>
      <.panel :if={@review} title="Review destructive installation" icon="shield" id="factory-review">
        <.setting_row label="USB location">
          {@review.location} · not a unique board identity
        </.setting_row>
        <.setting_row label="Firmware">{@review.version} · {@review.firmware}</.setting_row>
        <.setting_row label="eMMC capacity">{bytes(@review.capacity)}</.setting_row>
        <.setting_row label="Backup directory">{@review.backup}</.setting_row>
        <.setting_row label="Disk space">
          {bytes(@review.required_space)} required · {bytes(@review.available_space)} available at review
        </.setting_row>
        <code>SHA-256: {@review.sha256}</code>
        <p>
          A full eMMC user-area backup and checksum are mandatory before the first write.
          Every written region is read back and checked. The device resets only after verification.
          Installation is not power-loss atomic. Backup/readbacks are kept even on failure;
          never retry automatically after an uncertain result.
        </p>
        <p>
          Review expires after ten minutes and is single-use. Another operation cancels it.
          After expiry or failure, re-enter MASKROM before reviewing again.
        </p>
        <form id="confirm-factory" phx-submit="confirm_factory" class="ui-stack">
          <input type="hidden" name="review_id" value={@review.token} />
          <label>
            <input type="checkbox" name="identified" value="true" required />
            I physically verified this is the intended EC100 and accept erasing all existing data.
          </label>
          <label for="factory-confirmation">Type {@review.confirmation}</label>
          <input id="factory-confirmation" name="confirmation" autocomplete="off" required />
          <.button type="submit" variant="danger" disabled={@operation.status == :running}>
            Back up, erase and provision EC100
          </.button>
        </form>
      </.panel>
      <.panel title="Operation output" icon="clock"><.operation operation={@operation} /></.panel>
      <.panel title="Already running Nerves Gate?" icon="network">
        <p>
          Use a device's Firmware tab for a non-provisioning SSH A/B update, including over USB networking.
        </p>
        <.link navigate="/devices?kind=physical" class="ui-text-link">Choose an existing gateway</.link>
      </.panel>
    </main>
    """
  end

  defp factory_review(%{review: %{kind: :factory} = review}), do: review
  defp factory_review(_), do: nil
  defp bytes(value), do: "#{Float.round(value / 1_073_741_824, 2)} GiB"
end

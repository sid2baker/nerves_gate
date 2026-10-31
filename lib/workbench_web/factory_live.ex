defmodule WorkbenchWeb.FactoryLive do
  @moduledoc "Initial USB provisioning, separate from routine SSH updates. Mounting never probes USB."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.Live, only: [command: 2]

  def mount(_, _, socket), do: {:ok, assign(socket, :images, Workbench.Builds.images())}

  def handle_event("refresh_images", _, socket),
    do: {:noreply, assign(socket, :images, Workbench.Builds.images())}

  def handle_event("review_factory", params, socket),
    do: command(socket, Workbench.Jobs.review_factory(params))

  def handle_event("confirm_factory", params, socket),
    do:
      command(
        socket,
        Workbench.Jobs.confirm_factory(
          params["review_id"],
          params["confirmation"],
          params["identified"]
        )
      )

  def render(assigns) do
    assigns = assign(assigns, :review, factory_review(assigns.job))

    ~H"""
    <main class="ui-main ui-stack bench" id="factory-page">
      <.back_link navigate="/devices">Existing gateways and routine updates</.back_link>
      <.page_header
        eyebrow="Provision · Physical EC100 or EM300 · initial USB installation"
        title="Factory provisioning"
        description="Replace factory firmware over USB MASKROM. This is not a routine SSH update."
      />
      <.notice :if={@error} tone="warning" id="factory-error">
        <p role="alert">{@error}</p>
      </.notice>
      <.notice tone="warning" id="factory-warning">
        <p>
          <strong>Destructive: replaces the bootloader, partition layout, firmware and application data.</strong>
        </p>
        <p>
          Connect exactly one board to the workstation running mix dev and put it in MASKROM mode.
          Keep stable power connected. A serial console cannot flash it.
        </p>
        <ul>
          <li>
            EC100: use its Type-C download port and follow the board's watchdog/download-jumper
            instructions. Installs to eMMC.
          </li>
          <li>
            EM300: use the stock U-Boot serial procedure below, or hold the LOADER key while
            applying power, then connect its USB-C port. Installs to SPI NAND and erases the entire NAND, including the vendor system and its
            vendor-storage data. EM300 support is in bring-up; keep the vendor recovery image.
          </li>
        </ul>
        <p>
          USB identifies an RK3506, not a verified board or serial number: EC100 and EM300 look the
          same. The selected image chooses the board. You must physically identify it. Do not unplug,
          replace it, or connect another Rockchip device during review/install.
        </p>
      </.notice>
      <.panel title="EM300 · enter MASKROM using the serial console" icon="port">
        <ol id="em300-maskrom-steps">
          <li>
            Connect the debug UART at <strong>115200 baud, 8N1</strong> with flow control off.
            Keep serial logging enabled to capture the first Nerves boot.
          </li>
          <li>
            During stock firmware startup, press <strong>Ctrl+C</strong> repeatedly when U-Boot
            says to stop autoboot. Wait for its <code>=&gt;</code> prompt.
          </li>
          <li>
            Connect the board's USB-C download port to this workstation. At the U-Boot prompt,
            run <code>rbrom</code>. This resets into BootROM download mode without erasing NAND.
            This procedure requires the stock U-Boot command; it is not a Linux shell command.
          </li>
          <li>
            On the workstation, run <code>rkdeveloptool ld</code>
            and confirm it reports <strong>Maskrom</strong>. If the board is already in that mode, skip these steps.
          </li>
          <li>
            Select an EM300 image below, leave full backup enabled, then click <strong>Load RAM transport and review</strong>. Check EM300 / SPI NAND and the backup
            location before entering the displayed erasure confirmation.
          </li>
        </ol>
        <p>
          Provisioning backs up NAND first when enabled, then erases, writes and verifies the
          installation before resetting. Keep power, USB and UART connected. Do not erase flash
          or run saveenv just to enter MASKROM. If a job fails or its outcome is uncertain,
          inspect its result before retrying.
        </p>
      </.panel>
      <ol class="dev-workflow-steps" aria-label="Provisioning stages">
        <li>1 · Prepare image and identify board</li>
        <li>2 · Review and authorize erasure</li>
        <li>3 · Verify writes and reconnect</li>
      </ol>
      <.panel title="1 · Prepare and review" icon="port">
        <.link navigate="/develop/firmware" class="ui-text-link">Build an EC100 or EM300 image</.link>
        <p>
          Build firmware for the board first. Review verifies the image and boot artifacts, loads a temporary
          USB transport into RAM, reads the flash capacity and checks artifact/backup disk space. Review writes nothing to flash.
          EM300 staging also requires ubinize (mtd-utils) on the workbench host.
        </p>
        <form id="review-factory" phx-submit="review_factory" class="ui-stack">
          <label for="factory-image">Board firmware</label>
          <select
            id="factory-image"
            name="firmware"
            required
            disabled={@images == [] or @job.status == :running}
          >
            <option :for={image <- @images} value={image.path}>
              {String.upcase(image.target)} · {image.version} · {image.build}
            </option>
          </select>
          <label for="factory-backup">Full flash backup</label>
          <select id="factory-backup" name="backup" disabled={@job.status == :running}>
            <option value="true">Create full backup (recommended)</option>
            <option value="false">
              Skip full backup — I accept losing the existing firmware and data
            </option>
          </select>
          <p class="ui-help">
            Skipping saves the full-device read, not write verification. Keep any original backup safe;
            this run cannot restore the previous firmware/data without one. Readbacks are always retained.
          </p>
          <label for="factory-access">USB permissions</label>
          <select id="factory-access" name="sudo" disabled={@job.status == :running}>
            <option value="false">Direct USB access (udev permissions)</option>
            <option value="true">Noninteractive sudo (-n)</option>
          </select>
          <p class="ui-help">
            Install rkdeveloptool on the workbench host. For sudo access, authorize it in a terminal
            first (sudo -v); sudo policy must also allow the workbench process to run rkdeveloptool
            noninteractively. The workbench never prompts for or stores your password.
            A device appearing in rkdeveloptool ld does not prove read/write USB access.
          </p>
          <div class="ui-actions">
            <.button type="submit" disabled={@images == [] or @job.status == :running}>
              Load RAM transport and review
            </.button>
            <.button type="button" phx-click="refresh_images" variant="secondary">Refresh firmware list</.button>
          </div>
        </form>
      </.panel>
      <.panel
        :if={@review}
        title="2 · Review destructive installation"
        icon="shield"
        id="factory-review"
      >
        <.setting_row label="USB location">
          {@review.location} · not a unique board identity
        </.setting_row>
        <.setting_row label="Board">{@review.board} · {@review.storage}</.setting_row>
        <.setting_row label="Firmware">{@review.version} · {@review.firmware}</.setting_row>
        <.setting_row label={"#{@review.storage} capacity"}>{bytes(@review.capacity)}</.setting_row>
        <.setting_row label={"Full #{@review.storage} backup"}>
          {if Map.get(@review, :backup_enabled, true), do: "Enabled", else: "SKIPPED"}
        </.setting_row>
        <.setting_row label="Artifact/readback directory">{@review.backup}</.setting_row>
        <.setting_row label="Disk space">
          {bytes(@review.required_space)} required · {bytes(@review.available_space)} available at review
        </.setting_row>
        <code>SHA-256: {@review.sha256}</code>
        <p>
          <%= if Map.get(@review, :backup_enabled, true) do %>
            A full {@review.storage} backup and checksum will be saved before the first write.
          <% else %>
            <strong>No full backup will be made. Existing firmware and data cannot be recovered from this run.</strong>
          <% end %>
          Every written region is read back and checked. The device resets only after verification.
          Installation is not power-loss atomic. Backup/readbacks are kept even on failure;
          never retry automatically after an uncertain result.
        </p>
        <p>
          After verified writes the board resets. It appears on the Devices page once it is on
          your network and its node accepts the development cookie.
        </p>
        <p>
          Review expires after ten minutes and is single-use. Another job cancels it.
          After expiry or failure, re-enter MASKROM before reviewing again.
        </p>
        <form id="confirm-factory" phx-submit="confirm_factory" class="ui-stack">
          <input type="hidden" name="review_id" value={@review.token} />
          <label>
            <input type="checkbox" name="identified" value="true" required />
            I physically verified this is the intended {@review.board} and accept erasing all existing data.
          </label>
          <label for="factory-confirmation">Type {@review.confirmation}</label>
          <input id="factory-confirmation" name="confirmation" autocomplete="off" required />
          <.button type="submit" variant="danger" disabled={@job.status == :running}>
            {if Map.get(@review, :backup_enabled, true),
              do: "Back up, erase and provision #{@review.board}",
              else: "Erase and provision #{@review.board} WITHOUT BACKUP"}
          </.button>
        </form>
      </.panel>
      <.panel
        :if={@job.kind in ["factory_review", "factory_provision"]}
        title="3 · Progress and verification"
        icon="clock"
      >
        <.job job={@job} />
        <p :if={@job.kind == "factory_review" and @job.status == :failed} class="ui-help">
          This failed review's temporary files have been removed. Fix the reported cause, inspect the device and start a new review; do not copy a temporary loader command from an old run.
        </p>
      </.panel>
      <.panel title="Already running Nerves Gate?" icon="network">
        <p>
          Use a device's Firmware tab for a non-provisioning SSH A/B update, including over USB networking.
        </p>
        <.link navigate="/devices" class="ui-text-link">Choose an existing gateway</.link>
      </.panel>
    </main>
    """
  end

  defp factory_review(%{review: %{kind: :factory} = review}), do: review
  defp factory_review(_), do: nil
  defp bytes(value), do: "#{Float.round(value / 1_073_741_824, 2)} GiB"
end

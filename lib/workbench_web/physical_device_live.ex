defmodule WorkbenchWeb.PhysicalDeviceLive do
  @moduledoc "Unverified physical identity and explicitly reviewed SSH A/B updates. No QEMU controls."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.WorkbenchLive, only: [command: 2]

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :device_info, 1_000)
    {:ok, assign(socket, images: Workbench.Builds.images())}
  end

  def handle_params(params, _, socket) do
    device =
      Enum.find(Workbench.LANDiscovery.snapshot().devices, &(&1.address == params["address"]))

    tab = if params["tab"] in ["firmware", "tests"], do: params["tab"], else: "overview"
    {:noreply, assign(socket, address: params["address"], device: device, tab: tab)}
  end

  def handle_info(:device_info, socket) do
    Process.send_after(self(), :device_info, 1_000)

    device =
      Enum.find(
        Workbench.LANDiscovery.snapshot().devices,
        &(&1.address == socket.assigns.address)
      )

    {:noreply, assign(socket, :device, device)}
  end

  def handle_event(
        "hardware_test",
        %{"profile" => profile},
        %{assigns: %{device: device}} = socket
      )
      when not is_nil(device),
      do: command(socket, Workbench.Operations.start("hardware_test", device.address, profile))

  def handle_event("hardware_test", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("hardware_failover", params, %{assigns: %{device: device}} = socket)
      when not is_nil(device),
      do:
        command(
          socket,
          Workbench.Operations.start("hardware_failover", device.address, params["consent"])
        )

  def handle_event("hardware_failover", _, socket),
    do: command(socket, {:error, "Add this device's USB address first"})

  def handle_event("diagnostics", _, %{assigns: %{device: device}} = socket)
      when not is_nil(device),
      do: command(socket, Workbench.Operations.start("hardware_diagnostics", device.address))

  def handle_event("diagnostics", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("review_reboot", params, %{assigns: %{device: device}} = socket)
      when not is_nil(device),
      do:
        command(
          socket,
          Workbench.Operations.review_reboot(device.address, params["management"] || "ssh")
        )

  def handle_event("review_reboot", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("confirm_reboot", params, %{assigns: %{device: device}} = socket)
      when not is_nil(device) do
    review = Workbench.Operations.snapshot().review

    if review && review[:kind] == :reboot && review.address == device.address,
      do:
        command(
          socket,
          Workbench.Operations.confirm_reboot(params["review_id"], params["address"])
        ),
      else: command(socket, {:error, "Review reboot observation for this device first"})
  end

  def handle_event("confirm_reboot", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("cancel_observation", _, %{assigns: %{device: device}} = socket)
      when not is_nil(device),
      do: command(socket, Workbench.Operations.cancel_observation(device.address))

  def handle_event("cancel_observation", _, socket),
    do: command(socket, {:error, "No device observation to cancel"})

  def handle_event("refresh_images", _, socket),
    do: {:noreply, assign(socket, :images, Workbench.Builds.images())}

  def handle_event("read_info", _, %{assigns: %{device: device}} = socket)
      when not is_nil(device),
      do: command(socket, Workbench.Operations.start("device_info", device.address, nil))

  def handle_event("read_info", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("review_firmware", params, %{assigns: %{device: device}} = socket)
      when not is_nil(device) do
    # Destination, port and available local files are owned by this page, never submitted fields.
    if Enum.any?(Workbench.Builds.images(), &(&1.path == params["firmware"])) do
      command(
        socket,
        Workbench.Operations.review_firmware(%{
          "address" => device.address,
          "port" => 22,
          "verify_usb" => params["verify_usb"],
          "firmware" => params["firmware"]
        })
      )
    else
      command(
        socket,
        {:error, "Select an available EC100 image; refresh the list after building"}
      )
    end
  end

  def handle_event("review_firmware", _, socket),
    do: command(socket, {:error, "Add this device's address first"})

  def handle_event("confirm_firmware", params, socket) do
    review = Workbench.Operations.snapshot().review
    device = socket.assigns.device

    if device && review && Map.get(review, :address) == device.address do
      command(
        socket,
        Workbench.Operations.confirm_firmware(params["review_id"], params["address"])
      )
    else
      command(socket, {:error, "Review firmware for this device first"})
    end
  end

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="physical-device">
      <.back_link navigate="/devices">Devices</.back_link>
      <.notice :if={!@device} tone="warning" role="alert">
        Device is not in this session. Add its address on the Devices page first.
      </.notice>
      <div :if={@device} class="ui-stack">
        <.page_header
          eyebrow="Physical gateway"
          title={Workbench.Devices.name(@device)}
          description={@device.address}
        >
          <:actions>
            <.button
              href={@device.url}
              target="_blank"
              rel="noreferrer"
              variant="secondary"
              icon="external"
            >Open gateway</.button>
          </:actions>
        </.page_header>
        <div class="ui-actions">
          <.device_kind kind={:physical} /><.status>
            {cond do
              @device[:identity] ->
                "Identity read over verified SSH · not a live connection"

              @device[:usb_info] ->
                "Information read over direct USB HTTP · not authenticated SSH identity"

              true ->
                "Unverified identity · device not queried"
            end}
          </.status>
        </div>
        <nav class="dev-filters" aria-label="Device sections">
          <.link
            :for={
              {tab, label} <- [
                {"overview", "Overview"},
                {"tests", "Hardware tests"},
                {"firmware", "Procedures"}
              ]
            }
            patch={Workbench.Devices.physical_path(@device.address) <> "?tab=" <> tab}
            aria-current={if @tab == tab, do: "page"}
          >{label}</.link>
        </nav>
        <nav :if={@tab == "firmware"} class="dev-filters" aria-label="Physical device procedures">
          <a href="#device-setup">Setup / restore</a>
          <a href="#device-diagnostics">Diagnostics</a>
          <a href="#device-reboot">Reboot and verify</a>
          <a href="#firmware-update">Update and verify</a>
          <a href="#device-reset">Reset / recovery</a>
        </nav>
        <.panel :if={@tab == "overview"} title="Device information" icon="info">
          <.setting_row label="Address">{@device.address}</.setting_row>
          <.setting_row label="Target">{@device.target || "Not read yet"}</.setting_row>
          <.setting_row label="Running firmware">{@device.version || "Not read yet"}</.setting_row>
          <.setting_row label="Address source">
            {case @device.source do
              :manual -> "Manually added"
              :tailnet -> "Tailnet name · unverified gateway candidate"
              :usb -> "Reviewed USB port after factory provisioning"
              _ -> "LAN mDNS"
            end}
          </.setting_row>
          <.setting_row :if={@device[:usb_info]} label="USB runtime">
            {@device.usb_info.runtime}
          </.setting_row>
          <.setting_row :if={@device[:usb_info]} label="USB information read at">
            {@device.usb_info.read_at}
          </.setting_row>
          <.setting_row :if={@device[:identity]} label="Serial">
            {@device.identity.values["serial"] || "Not reported"}
          </.setting_row>
          <.setting_row :if={@device[:identity]} label="Architecture">
            {@device.identity.values["architecture"] || "Not reported"}
          </.setting_row>
          <.setting_row :if={@device[:identity]} label="Information read at">
            {@device.identity.read_at}
          </.setting_row>
          <.setting_row label="SSH">
            Port 22 · verified host key and public-key authentication
          </.setting_row>
          <p :if={@device[:info_read] && @device.info_read.status == :reading} role="status">
            Reading information over verified SSH…
          </p>
          <.notice
            :if={@device[:info_read] && @device.info_read.status == :failed}
            tone="warning"
            id="device-info-failed"
          >
            {@device.info_read.message}
          </.notice>
          <.button phx-click="read_info" disabled={@operation.status == :running}>
            {if @device[:info_read] && @device.info_read.status == :failed,
              do: "Retry information read",
              else: "Read device information"}
          </.button>
          <p class="ui-help">
            New candidates automatically get one authenticated SSH information attempt on port 22
            to fetch the running target, version and serial. Failed attempts are not retried on refresh;
            use Retry after fixing access. Reading sends no firmware and does not reboot. The host key must already be verified and your SSH key authorized.
            LAN advertisements and tailnet names are not authenticated gateway identity. Gateway HTTPS access and SSH information reads are separate connections.
          </p>
        </.panel>
        <.panel
          :if={@tab == "tests"}
          title="Read-only hardware tests"
          icon="check"
          id="hardware-tests"
        >
          <p>
            Read-only checks against this physical EC100 over verified SSH on LAN, Tailscale or USB. No independent USB connection is required for readiness checks. Unknown host keys are never accepted. Disruptive failover testing below still requires verified independent USB management.
          </p>
          <form id="hardware-test" phx-submit="hardware_test" class="ui-stack">
            <label>
              Expected network profile
              <select name="profile">
                <option value="ethernet">Ethernet</option>
                <option value="cellular">4G</option>
                <option value="backup">Ethernet with 4G backup</option>
              </select>
            </label>
            <.button type="submit" disabled={@operation.status == :running}>Run read-only readiness checks</.button>
          </form>
          <p class="ui-help">
            Configure the intended profile on the gateway first. These checks do not enable cellular, unlock a SIM, change routes or consume a PIN attempt. They read existing connectivity observations: passing backup readiness does not prove cable-loss takeover or failback. Use the separately authorized operator-assisted test below to exercise those transitions.
          </p>
          <.procedure_result
            operation={@operation}
            address={@device.address}
            kinds={["hardware_test"]}
          />
        </.panel>
        <.panel
          :if={@tab == "tests"}
          title="Ethernet loss → 4G takeover → Ethernet return"
          icon="network"
          id="hardware-failover"
        >
          <p>
            Operator-assisted test on a dedicated bench device. Prepare Ethernet with 4G backup and a ready SIM/data plan first. USB management must remain connected throughout. The workbench only observes; you unplug and restore Ethernet when prompted.
          </p>
          <form id="hardware-failover-test" phx-submit="hardware_failover" class="ui-stack">
            <label><input type="checkbox" name="consent" value="true" required />
            I authorize cellular data use and Ethernet disruption, can restore all uplink cables, and will keep USB and power connected.</label>
            <.button type="submit" disabled={@operation.status == :running}>Start assisted failover test</.button>
          </form>
          <p class="ui-help">
            Each phase has a two-minute deadline. Link loss and source selection must both be observed. Restore Ethernet on failure, cancellation or a lost workbench connection; there is no automatic cable restoration.
          </p>
          <.procedure_result
            operation={@operation}
            address={@device.address}
            kinds={["hardware_failover"]}
          />
        </.panel>
        <.panel
          :if={@tab == "firmware"}
          title="Set up or restore configuration"
          icon="network"
          id="device-setup"
        >
          <ol>
            <li>
              Use a dedicated device, verify its identity and keep independent USB access. Record the intended configuration securely before changing it; this is not an automatic backup.
            </li>
            <li>
              Open Internet settings, select Ethernet, 4G or Ethernet with 4G backup, and finish SIM commissioning if needed. Confirm or restore any network trial in the gateway itself.
            </li>
            <li>
              Configure remote access and authorized SSH keys on the gateway. Never paste private keys or SIM credentials into the workbench.
            </li>
            <li>
              Run the matching read-only readiness checks, then explicitly authorize the assisted failover test if required. Restoring an earlier configuration remains a deliberate gateway-side change, not a replay of captured secrets.
            </li>
          </ol>
          <div class="ui-actions">
            <.button
              href={to_string(URI.merge(@device.url, "network"))}
              target="_blank"
              rel="noreferrer"
              variant="secondary"
            >Internet setup</.button>
            <.button
              href={to_string(URI.merge(@device.url, "remote"))}
              target="_blank"
              rel="noreferrer"
              variant="secondary"
            >Remote access</.button>
            <.button
              href={to_string(URI.merge(@device.url, "settings"))}
              target="_blank"
              rel="noreferrer"
              variant="secondary"
            >Device settings</.button>
          </div>
        </.panel>
        <.panel
          :if={@tab == "firmware"}
          title="Collect diagnostics"
          icon="info"
          id="device-diagnostics"
        >
          <p>
            Collect a sanitized, timestamped snapshot over verified SSH on LAN, Tailscale or USB: identity, boot, firmware validation and network/cellular readiness only. No raw logs, settings, credentials, APN or SIM identifiers. Review before sharing; device serial and management address are included.
          </p>
          <.button phx-click="diagnostics" disabled={@operation.status == :running}>Collect diagnostic snapshot</.button>
          <.procedure_result
            operation={@operation}
            address={@device.address}
            kinds={["hardware_diagnostics"]}
          />
        </.panel>
        <.panel
          :if={@tab == "firmware"}
          title="Reboot and verify · physical button"
          icon="settings"
          id="device-reboot"
        >
          <p>
            Review the current identity and boot over LAN/Tailscale SSH or independent USB. After typing the reviewed address, wait until observation is armed, then use the board's button as instructed. The workbench sends no remote reboot command. It waits up to three minutes for reconnection and a healthy new boot. If remote access does not return, verification stays incomplete; no reboot is repeated.
          </p>
          <form id="review-reboot" phx-submit="review_reboot" class="ui-stack">
            <label>Management connection<select name="management">
              <option value="ssh">Verified SSH · LAN / Tailscale / USB</option>
              <option value="usb">Require independent USB · bound interface</option>
            </select></label>
            <.button type="submit" disabled={@operation.status == :running}>Review reboot observation</.button>
          </form>
          <.notice
            :if={
              @operation.review && @operation.review[:kind] == :reboot &&
                @operation.review.address == @device.address
            }
            tone="warning"
            id="reboot-review"
          >
            <p>
              {@operation.review.management} · serial {@operation.review.serial} · firmware {@operation.review.version}. Review expires in ten minutes. Do not press the button yet.
            </p>
            <form id="confirm-reboot" phx-submit="confirm_reboot" class="ui-stack">
              <input type="hidden" name="review_id" value={@operation.review.token} />
              <input
                type="text"
                name="address"
                aria-label="Confirm reboot observation address"
                placeholder={@operation.review.address}
                required
                autocomplete="off"
              />
              <.button type="submit">Arm observation; I will reboot using the button</.button>
            </form>
          </.notice>
          <p class="ui-help">
            Once armed: short-press and release once, then hold 5–10 seconds and release while RUN blinks slowly. Never hold 30 seconds (factory reset). A first release after startup/input loss only arms the button. Unknown outcomes require inspection, not repeated presses.
          </p>
          <.procedure_result
            operation={@operation}
            address={@device.address}
            kinds={["reboot_review", "reboot_verify"]}
          />
        </.panel>
        <.panel
          :if={@tab == "firmware"}
          title="Update and verify firmware"
          icon="settings"
          id="firmware-update"
        >
          <p class="ui-help">
            Standard SSH A/B update, not disk flashing or factory reset. Review is read-only
            on the device. Updating writes firmware and reboots it. Use an authorized SSH key
            and a verified host key in ~/.ssh/known_hosts. An active ssh-agent must hold your key;
            otherwise standard ~/.ssh key files are used. Password prompts are not available.
            Only compatible EC100 images and devices are accepted by the backend.
          </p>
          <.link navigate="/develop/firmware" class="ui-text-link">Build a firmware image</.link>
          <form id="review-firmware" phx-submit="review_firmware" class="ui-stack">
            <label>
              Procedure
              <select name="verify_usb">
                <option value="ssh">SSH update, reboot and verify · LAN / Tailscale / USB</option>
                <option value="true">Require independent USB · update, reboot and verify</option>
                <option value="false">Standard SSH update · verify manually</option>
              </select>
            </label>
            <p class="ui-help">
              Reconnect verification works over verified SSH on LAN/Tailscale or USB. Choosing independent USB additionally verifies the direct management route and binds SSH to that interface. After the single authorized upload, verification requires a new boot, unchanged identity, reviewed firmware and healthy state. Loss of remote management leaves verification incomplete. Verification failure does not upload again. Setup remains in the gateway UI; data reset has its own manual recovery checklist below.
            </p>
            <label class="ui-stack">Firmware image<select
              name="firmware"
              required
              disabled={@images == []}
            >
              <option value="">Select a built EC100 image…</option>
              <option :for={image <- @images} value={image.path}>
                {image.version} · {image.build}
              </option>
            </select></label>
            <p :if={@images == []} class="ui-help">
              No EC100 images available. Build firmware, then refresh this list.
            </p>
            <p class="ui-help">
              SSH port 22. Image metadata is shown for selection; archive integrity and device compatibility are checked during review.
            </p>
            <.button type="submit" disabled={@operation.status == :running || @images == []}>Review firmware and device</.button>
          </form>
          <.button phx-click="refresh_images" variant="secondary">Refresh firmware list</.button>
          <.firmware_confirmation
            :if={
              @operation.review && @operation.review[:kind] not in [:reboot, :factory, :app_install] &&
                Map.get(@operation.review, :address) == @device.address
            }
            review={@operation.review}
          />
          <.procedure_result
            operation={@operation}
            address={@device.address}
            kinds={["firmware_review", "firmware_update"]}
          />
        </.panel>
        <.panel
          :if={@tab == "firmware"}
          title="Factory reset and recovery"
          icon="shield"
          id="device-reset"
        >
          <.notice tone="warning">
            Destructive, manual procedure — not a workbench reset button. Factory reset deletes data, saved network settings, SSH keys and Tailscale identity. It preserves firmware slots and the bootloader; it is not secure erasure. Keep serial recovery available: USB networking/authentication may disappear.
          </.notice>
          <ol>
            <li>
              Identify this board physically and preserve required data/configuration securely. Finish or inspect any firmware update first; admitted recovery may remain blocked until reboot.
            </li>
            <li>
              Only when deliberate data erasure is intended: short-press and release to arm, then hold at least 30 seconds until all LEDs flash quickly and release. Do not confuse this with the 5–10 second reboot gesture.
            </li>
            <li>
              Reconnect and set up the gateway manually. Deleted SSH credentials can prevent authenticated verification; a USB HTTP/version observation alone does not prove reset completion.
            </li>
            <li>
              If quiescing/unmounting fails, services may remain stopped. Inspect via serial recovery; never blindly repeat reset.
            </li>
          </ol>
        </.panel>
        <.procedure_result
          :if={@tab == "overview"}
          operation={@operation}
          address={@device.address}
          kinds={["device_info"]}
        />
      </div>
    </main>
    """
  end
end

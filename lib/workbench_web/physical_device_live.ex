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

    tab = if params["tab"] == "firmware", do: "firmware", else: "overview"
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
            :for={{tab, label} <- [{"overview", "Overview"}, {"firmware", "Firmware"}]}
            patch={Workbench.Devices.physical_path(@device.address) <> "?tab=" <> tab}
            aria-current={if @tab == tab, do: "page"}
          >{label}</.link>
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
        <.panel :if={@tab == "firmware"} title="Firmware update" icon="settings" id="firmware-update">
          <p class="ui-help">
            Standard SSH A/B update, not disk flashing or factory reset. Review is read-only
            on the device. Updating writes firmware and reboots it. Use an authorized SSH key
            and a verified host key in ~/.ssh/known_hosts. An active ssh-agent must hold your key;
            otherwise standard ~/.ssh key files are used. Password prompts are not available.
            Only compatible EC100 images and devices are accepted by the backend.
          </p>
          <.link navigate="/develop/firmware" class="ui-text-link">Build a firmware image</.link>
          <form id="review-firmware" phx-submit="review_firmware" class="ui-stack">
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
            :if={@operation.review && Map.get(@operation.review, :address) == @device.address}
            review={@operation.review}
          />
        </.panel>
        <.operation
          :if={
            hd(String.split(operation_path(@operation), "?")) ==
              Workbench.Devices.physical_path(@device.address)
          }
          operation={@operation}
        />
      </div>
    </main>
    """
  end
end

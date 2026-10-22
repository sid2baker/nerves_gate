defmodule DevWeb.FirmwareLive do
  @moduledoc "Explicit isolated firmware builds. Building never installs or flashes firmware."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import DevWeb.Components
  import DevWeb.WorkbenchLive, only: [command: 2]

  def mount(_, _, socket), do: {:ok, socket}

  def handle_event("build", %{"target" => target}, socket),
    do: command(socket, Dev.Workbench.operate("firmware", target, nil))

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="firmware-page">
      <.page_header
        eyebrow="Developer workbench"
        title="Firmware"
        description="Build images locally. Choose a device separately to review and authorize an update."
      />
      <.panel title="Build firmware" icon="port" id="firmware-build">
        <form id="build-firmware" phx-submit="build" class="ui-actions">
          <select name="target" aria-label="Firmware build target">
            <option value="ec100">EC100 physical controller</option><option value="x86_64">
              x86_64 QEMU
            </option>
          </select>
          <.button type="submit" disabled={@operation.status == :running}>Build firmware</.button>
        </form>
        <p class="ui-help">
          Building never flashes a device. QEMU builds require stopped/reset simulated devices; EC100 builds do not. Backend admission is authoritative.
        </p>
      </.panel>
      <.panel title="Operation output" icon="clock"><.operation operation={@operation} /></.panel>
      <.panel title="Initial EC100 installation" icon="usb">
        <p>
          Still running factory firmware? Provision over USB MASKROM with a mandatory backup and explicit erase confirmation.
        </p>
        <.link navigate="/factory" class="ui-text-link">Factory provisioning</.link>
      </.panel>
      <.panel title="Use a firmware image" icon="network">
        <p>
          For a physical gateway, open its device page and review the image before explicitly authorizing an SSH A/B update.
        </p>
        <.link navigate="/devices?kind=physical" class="ui-text-link">Choose a physical device</.link>
        <p class="ui-help">
          Images are written to firmware/_build/TARGET_dev/nerves/images/nerves_gate.fw. Rebuilds overwrite that output; firmware review creates its own immutable snapshot.
        </p>
      </.panel>
    </main>
    """
  end
end

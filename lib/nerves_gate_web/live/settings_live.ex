defmodule NervesGateWeb.SettingsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.Layouts, only: [settings_nav: 1]
  alias NervesGateWeb.RemoteStatus

  on_mount({NervesGateWeb.Observations, :status})

  def handle_event("identify", _, socket), do: reply(socket, NervesGate.identify())

  def handle_event("button-mode", %{"mode" => mode}, socket),
    do: reply(socket, NervesGate.button_mode(mode))

  defp reply(socket, result) do
    socket = socket |> clear_flash() |> assign(:projection, NervesGate.status())

    case result do
      :ok -> {:noreply, socket}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def render(assigns) do
    ~H"""
    <.page_header
      title="Settings"
      description="Configure this gateway. Everyday connection details live in Equipment and Remote access."
    />
    <.settings_nav current={:settings} />
    <section class="ui-connections" aria-label="Gateway settings">
      <.navigation_card
        title="Network"
        icon="network"
        href="/settings/network"
        id="settings-network"
        status={network_status(@projection.network)}
      >
        Ethernet port assignments, Internet and equipment addresses. USB stays independent for recovery.
      </.navigation_card>
      <.navigation_card
        title="Tailscale"
        icon="shield"
        href="/settings/tailscale"
        id="settings-tailscale"
        status={RemoteStatus.label(@projection.remote_access)}
      >
        Connect to your tailnet, change the gateway name, or disconnect.
      </.navigation_card>
    </section>
    <.panel title="Button and LED" icon="settings" id="physical-controls">
      <.notice :if={@projection.indicators.simulated}>
        Preview mode · simulated button and LED. Workstation hardware is never used.
      </.notice>
      <.notice :if={Phoenix.Flash.get(@flash, :error)} tone="warning" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </.notice>
      <.notice :if={@projection.indicators.led.error} tone="warning" role="alert">
        {@projection.indicators.led.error.message}
      </.notice>
      <.setting_row label="Run LED">
        <span id="led-state">
          {cond do
            @projection.indicators.led.restore_pending -> "Restoration pending"
            @projection.indicators.led.identifying -> "Identifying…"
            @projection.indicators.led.available -> "Available"
            true -> "Unavailable"
          end}
        </span>
      </.setting_row>
      <p class="ui-help">
        Identify blinks the mapped EC100 run LED for five seconds, then restores its previous value.
        Physical on/off polarity is not calibrated. The second LED is unsupported: its mapping is unverified.
        A kernel-controlled LED is left untouched.
      </p>
      <.button
        id="identify-gateway"
        phx-click="identify"
        disabled={!@projection.actions["identify"].enabled}
      >
        Identify gateway
      </.button>
      <.setting_row label="User button">
        {if @projection.indicators.button.available, do: "Detected", else: "Unavailable"}
      </.setting_row>
      <div class="ui-actions" role="group" aria-label="Button behavior">
        <.button
          id="button-disabled"
          variant="secondary"
          phx-click="button-mode"
          phx-value-mode="disabled"
          aria-pressed={to_string(@projection.indicators.button.mode == "disabled")}
        >
          Disabled
        </.button>
        <.button
          id="button-identify"
          variant="secondary"
          phx-click="button-mode"
          phx-value-mode="identify"
          disabled={!@projection.actions["button_mode"].enabled}
          aria-pressed={to_string(@projection.indicators.button.mode == "identify")}
        >
          Identify on press
        </.button>
      </div>
      <p class="ui-help">
        Button behavior lasts until restart and defaults to disabled. Holding the button does not repeat
        or extend a blink. No reset, network or Tailscale action is bound to it.
      </p>
      <p :if={@projection.indicators.button.last_pressed_at} id="button-last-press" class="ui-help">
        Last press: {DateTime.from_unix!(@projection.indicators.button.last_pressed_at, :millisecond)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")}
      </p>
    </.panel>
    <.panel title="Device information" icon="info">
      <.setting_row label="Gateway name">
        {@projection.remote_access.hostname || "Not set"}
      </.setting_row>
      <.setting_row label="Firmware">{@projection.system.firmware}</.setting_row>
      <.setting_row label="Target">{@projection.system.target}</.setting_row>
    </.panel>
    """
  end

  defp network_status(%{available: false}), do: "Unavailable"
  defp network_status(%{recovering: true}), do: "Restoring settings"
  defp network_status(%{pending: trial}) when not is_nil(trial), do: "Awaiting save"
  defp network_status(%{setup_completed: true}), do: "Configured"
  defp network_status(_), do: "Not configured"
end

defmodule NervesGateWeb.SettingsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.Layouts, only: [settings_nav: 1]
  alias NervesGateWeb.RemoteStatus

  on_mount({NervesGateWeb.Observations, :status})

  def handle_event("identify", _, socket), do: reply(socket, NervesGate.identify())

  def handle_event(_, _, socket) do
    {:noreply, socket}
  end

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
      <.navigation_card title="Buses" icon="port" href="/settings/buses" id="settings-buses">
        CAN listen-only bitrate and RS485 diagnostic opt-in. No automatic bus traffic.
      </.navigation_card>
    </section>
    <.panel title="Button and LEDs" icon="settings" id="physical-controls">
      <.notice :if={@projection.indicators.simulated}>
        Preview mode · simulated button, LEDs and recovery. Workstation hardware is never used.
      </.notice>
      <.notice :if={Phoenix.Flash.get(@flash, :error)} tone="warning" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </.notice>
      <.notice :if={@projection.indicators.led.error} tone="warning" role="alert">
        {@projection.indicators.led.error.message}
      </.notice>
      <.notice
        :if={@projection.indicators.recovery.error}
        tone="warning"
        role="alert"
        id="recovery-error"
      >
        {@projection.indicators.recovery.error.message}
      </.notice>
      <.setting_row label="Status LEDs">
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
        RUN: on while the application runs. USER1: off when Tailscale is disconnected,
        on with confirmed Internet and healthy Tailscale, slow blink while connecting or
        unknown, fast blink for connectivity faults lasting two seconds.
        USER2: off with no known alarms, slow blink for warnings or unknown alarm status,
        fast blink for errors. Restore and recovery failures report immediately.
        Slow is 1 Hz; fast is 4 Hz.
        Kernel-controlled LEDs are left untouched.
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
      <p class="ui-help">
        Actions happen only on release: under 2 seconds identifies for 5 seconds;
        2–5 seconds does nothing; 5–30 seconds reboots; 30 seconds or more requests factory reset.
        While held: RUN blinks slowly at 5–25 seconds, USER2 blinks fast at 25–30 seconds,
        and all LEDs blink fast from 30 seconds. Identify resumes current status afterward.
      </p>
      <p class="ui-help">
        After startup or input loss, release once to arm the button. Factory reset is simulated
        in preview. On EC100 it deletes all saved data, including network settings and credentials,
        then reboots. Physical reset qualification is still pending. Failed recovery is never
        automatically retried. RUN may stay on after an abrupt VM failure.
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

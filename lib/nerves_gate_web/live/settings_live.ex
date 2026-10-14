defmodule NervesGateWeb.SettingsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket),
    do: {:ok, assign(socket, :key_form, to_form(%{"public_key" => ""}, as: :ssh))}

  def handle_event("key-draft", %{"ssh" => params}, socket),
    do: {:noreply, assign(socket, :key_form, to_form(params, as: :ssh))}

  def handle_event("add-key", %{"ssh" => %{"public_key" => key}}, socket) do
    socket = clear_flash(socket)

    case NervesGateWeb.Backend.ssh_add_key(key) do
      :ok ->
        {:noreply,
         socket
         |> assign(:key_form, to_form(%{"public_key" => ""}, as: :ssh))
         |> put_flash(:info, "SSH key saved.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("remove-key", %{"fingerprint" => fingerprint}, socket) do
    socket = clear_flash(socket)

    case NervesGateWeb.Backend.ssh_remove_key(fingerprint) do
      :ok ->
        {:noreply,
         put_flash(socket, :info, "SSH key removed. Existing SSH sessions remain open.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("identify", _, socket) do
    result = NervesGateWeb.Backend.identify()
    socket = clear_flash(socket)

    case result do
      :ok -> {:noreply, socket}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event(_, _, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.page_header title="Settings" description={@projection.remote_access.hostname || "Nerves Gate"} />
    <.notice :if={Phoenix.Flash.get(@flash, :error)} tone="warning" role="alert">
      {Phoenix.Flash.get(@flash, :error)}
    </.notice>
    <.notice :if={Phoenix.Flash.get(@flash, :info)} tone="good" role="status">
      {Phoenix.Flash.get(@flash, :info)}
    </.notice>
    <.panel id="ssh-settings" title="SSH access" icon="lock">
      <p class="ui-help">
        Over USB IPv4, sign in as <code>root</code> with password <code>nerves_gate</code>; no key is
        required. Ethernet and Tailscale require an authorized public key.
        SSH grants full device access, including firmware updates.
      </p>
      <.notice :if={@projection.ssh.error} tone="warning" role="alert">
        {@projection.ssh.error.message}
      </.notice>
      <p :if={@projection.ssh.available and @projection.ssh.keys == []} class="ui-help">
        No SSH keys saved. Add a key to enable SSH over Ethernet or Tailscale.
      </p>
      <ul id="ssh-keys" class="ui-ssh-keys">
        <li :for={key <- @projection.ssh.keys}>
          <div>
            <strong>{if key.comment == "", do: key.type, else: key.comment}</strong>
            <code>{key.fingerprint}</code>
          </div>
          <.button
            variant="quiet"
            phx-click="remove-key"
            phx-value-fingerprint={key.fingerprint}
            data-confirm="Remove this SSH key? New logins using it will be denied. Removing the last key leaves USB password access only."
            disabled={!@projection.actions["ssh.remove_key"].enabled}
            aria-label={"Remove SSH key #{key.fingerprint}"}
          >Remove</.button>
        </li>
      </ul>
      <.form
        for={@key_form}
        id="ssh-key-form"
        class="ui-stack"
        phx-change="key-draft"
        phx-submit="add-key"
      >
        <div class="ui-field">
          <label for="ssh_public_key">Public key</label>
          <textarea
            id="ssh_public_key"
            name={@key_form[:public_key].name}
            rows="3"
            maxlength="8192"
            required
            spellcheck="false"
            autocomplete="off"
            placeholder="ssh-ed25519 AAAA… name@computer"
            aria-describedby="ssh-key-help"
            disabled={!@projection.actions["ssh.add_key"].enabled}
          >{@key_form[:public_key].value}</textarea>
          <p id="ssh-key-help" class="ui-help">
            Paste one Ed25519, RSA or ECDSA public key (the .pub file), never a private key.
            Keys are saved on this device and survive reboots and firmware updates.
          </p>
        </div>
        <.button
          type="submit"
          phx-disable-with="Saving…"
          disabled={!@projection.actions["ssh.add_key"].enabled}
        >
          Add SSH key
        </.button>
      </.form>
    </.panel>
    <.panel title="Device information" icon="info">
      <.setting_row label="Firmware">{@projection.system.firmware}</.setting_row>
      <.setting_row label="Target">{@projection.system.target}</.setting_row>
      <.setting_row label="Runtime">
        Elixir {@projection.system.elixir} · OTP {@projection.system.otp}
      </.setting_row>
      <.notice :if={@projection.indicators.simulated}>
        Preview mode · simulated button, LEDs and recovery. Workstation hardware is never used.
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
      <.button
        id="identify-gateway"
        phx-click="identify"
        disabled={!@projection.actions["identify"].enabled}
      >
        Identify gateway
      </.button>
    </.panel>
    <details
      id="physical-controls"
      class="ui-details"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>Button and LEDs</summary>
      <div class="ui-stack">
        <p class="ui-help">
          RUN: on while the application runs. USER1: off when Tailscale is disconnected,
          on with confirmed Internet and healthy Tailscale, slow blink while connecting or
          unknown, fast blink for connectivity faults lasting two seconds.
          USER2: off with no known alarms, slow blink for warnings or unknown alarm status,
          fast blink for errors. Restore and recovery failures report immediately.
          Slow is 1 Hz; fast is 4 Hz. Kernel-controlled LEDs are left untouched.
        </p>
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
          Last press: {DateTime.from_unix!(
            @projection.indicators.button.last_pressed_at,
            :millisecond
          )
          |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")}
        </p>
      </div>
    </details>
    """
  end
end

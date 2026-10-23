defmodule NervesGateWeb.CellularPanel do
  @moduledoc "SIM commissioning beside Internet settings. Credentials are never LiveView drafts."
  use Phoenix.LiveComponent
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.Backend

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:generation, fn -> 0 end)
     |> assign_new(:message, fn -> nil end)}
  end

  def handle_event("refresh", _, socket), do: reply(socket, Backend.cellular_refresh())

  def handle_event("unlock", params, socket),
    do: reply(socket, Backend.cellular_unlock(params["pin"]))

  def handle_event("save_pin", params, socket),
    do: reply(socket, Backend.cellular_save_pin(params["pin"]))

  def handle_event("forget_pin", _, socket),
    do: reply(socket, Backend.cellular_forget_pin())

  def handle_event("change_pin", params, socket) do
    if params["new_pin"] == params["repeat_pin"],
      do:
        reply(
          socket,
          Backend.cellular_change_pin(
            params["current_pin"],
            params["new_pin"]
          )
        ),
      else: reply(socket, {:error, %{message: "The new PINs do not match."}})
  end

  def handle_event("set_pin_lock", params, socket) do
    enabled =
      case params["enabled"] do
        "true" -> true
        "false" -> false
        _ -> nil
      end

    if enabled == false and params["acknowledged"] != "true",
      do:
        reply(
          socket,
          {:error, %{message: "Acknowledge that disabling the PIN removes SIM protection."}}
        ),
      else:
        reply(
          socket,
          Backend.cellular_set_pin_lock(enabled, params["pin"])
        )
  end

  defp reply(socket, result) do
    message =
      case result do
        :ok ->
          "Request accepted. Watch cellular status for completion. No PIN retry will be sent."

        {:error, error} ->
          error.message
      end

    # Replacing each form removes all entered passwords, including on rejection.
    # No phx-change or automatic form recovery: never resend a PIN on reconnect.
    {:noreply, assign(socket, generation: socket.assigns.generation + 1, message: message)}
  end

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :cellular,
        Map.get(assigns.projection, :cellular, NervesGate.Network.Cellular.view(nil))
      )

    content(assigns)
  end

  @doc false
  def content(assigns) do
    ~H"""
    <section id={@id} class="ui-stack" aria-label="Cellular commissioning">
      <.panel title="Cellular" icon="internet">
        <%= cond do %>
          <% not @cellular.supported -> %>
            <p>Cellular commissioning is not supported on this target.</p>
          <% @cellular.present != true -> %>
            <.notice tone="warning">
              No 4G modem detected. Cellular setup is unavailable; Ethernet still works.
            </.notice>
          <% not @cellular.enabled -> %>
            <p>
              Cellular is disabled. Apply and save a 4G Internet source above before checking the SIM.
            </p>
          <% true -> %>
            <.setting_row label="SIM">{sim_label(@cellular.sim)}</.setting_row>
            <.setting_row label="PIN protection">{lock_label(@cellular.pin_lock)}</.setting_row>
            <.setting_row label="PIN attempts remaining">
              {@cellular.pin_attempts_remaining || "Unknown"}
            </.setting_row>
            <.setting_row label="Registration">
              {registration_label(@cellular.registration)}
            </.setting_row>
            <.setting_row label="Operator">{@cellular.operator || "Unknown"}</.setting_row>
            <.setting_row label="Signal (RSSI)">
              {if is_integer(@cellular.signal_dbm), do: "#{@cellular.signal_dbm} dBm", else: "Unknown"}
            </.setting_row>
            <p :if={@cellular.refreshed_at} class="ui-help">
              Last observed: {Calendar.strftime(
                DateTime.from_unix!(@cellular.refreshed_at, :millisecond),
                "%H:%M:%S UTC"
              )}. Unknown values are not proof of a missing SIM.
            </p>
            <.button
              phx-click="refresh"
              phx-target={@myself}
              variant="secondary"
              disabled={!enabled?(@projection, "cellular.refresh")}
            >
              Refresh cellular status
            </.button>
            <.notice
              :if={@cellular.sim in [:puk_required, :puk2_required, :pin2_required]}
              tone="warning"
            >
              This SIM needs carrier/phone recovery. PUK and PIN2 operations are not supported here. Never guess a code.
            </.notice>
            <form
              :if={@cellular.sim == :pin_required}
              id={"cellular-unlock-#{@generation}"}
              phx-submit="unlock"
              phx-target={@myself}
              class="ui-stack"
            >
              <label for="cellular-unlock-pin">Existing SIM PIN</label>
              <input
                id="cellular-unlock-pin"
                name="pin"
                type="password"
                inputmode="numeric"
                autocomplete="off"
                pattern="[0-9]{4,8}"
                minlength="4"
                maxlength="8"
                required
              />
              <p class="ui-help">
                Incorrect PINs consume SIM attempts. After a verified unlock, the PIN is stored privately on this device for the same SIM after restart. Unlocking does not disable PIN protection.
              </p>
              <.button type="submit" disabled={!enabled?(@projection, "cellular.unlock")}>Unlock and save PIN</.button>
            </form>
            <details :if={@cellular.sim == :ready}>
              <summary>Advanced SIM security</summary>
              <div class="ui-stack">
                <p>
                  SIM security changes are permanent, not part of the network rollback trial. Successful PIN changes and enabling protection update the saved PIN; disabling protection forgets it. An uncertain result blocks automatic unlock until explicit verification.
                </p>
                <form
                  id={"cellular-save-pin-#{@generation}"}
                  phx-submit="save_pin"
                  phx-target={@myself}
                  class="ui-stack"
                >
                  <label for="cellular-save-pin">Current SIM PIN to remember</label>
                  <input
                    id="cellular-save-pin"
                    name="pin"
                    type="password"
                    inputmode="numeric"
                    autocomplete="off"
                    pattern="[0-9]{4,8}"
                    minlength="4"
                    maxlength="8"
                    required
                  />
                  <p class="ui-help">
                    Verification uses one PIN attempt and keeps the SIM's current protection setting. Use this to save or repair automatic unlock when the SIM is already ready.
                  </p>
                  <.button type="submit" disabled={!enabled?(@projection, "cellular.save_pin")}>
                    Verify and save PIN
                  </.button>
                </form>
                <form
                  id={"cellular-change-pin-#{@generation}"}
                  phx-submit="change_pin"
                  phx-target={@myself}
                  class="ui-stack"
                >
                  <label for="cellular-current-pin">Current PIN</label>
                  <input
                    id="cellular-current-pin"
                    name="current_pin"
                    type="password"
                    inputmode="numeric"
                    autocomplete="off"
                    pattern="[0-9]{4,8}"
                    minlength="4"
                    maxlength="8"
                    required
                  />
                  <label for="cellular-new-pin">New PIN</label>
                  <input
                    id="cellular-new-pin"
                    name="new_pin"
                    type="password"
                    inputmode="numeric"
                    autocomplete="off"
                    pattern="[0-9]{4,8}"
                    minlength="4"
                    maxlength="8"
                    required
                  />
                  <label for="cellular-repeat-pin">Repeat new PIN</label>
                  <input
                    id="cellular-repeat-pin"
                    name="repeat_pin"
                    type="password"
                    inputmode="numeric"
                    autocomplete="off"
                    pattern="[0-9]{4,8}"
                    minlength="4"
                    maxlength="8"
                    required
                  />
                  <.button type="submit" disabled={!enabled?(@projection, "cellular.change_pin")}>Change SIM PIN once</.button>
                </form>
                <form
                  id={"cellular-pin-lock-#{@generation}"}
                  phx-submit="set_pin_lock"
                  phx-target={@myself}
                  class="ui-stack"
                >
                  <label for="cellular-pin-protection">PIN protection after modem power loss</label>
                  <select id="cellular-pin-protection" name="enabled">
                    <option value="true">Require PIN</option>
                    <option value="false">Do not require PIN</option>
                  </select>
                  <label for="cellular-lock-pin">Current PIN</label>
                  <input
                    id="cellular-lock-pin"
                    name="pin"
                    type="password"
                    inputmode="numeric"
                    autocomplete="off"
                    pattern="[0-9]{4,8}"
                    minlength="4"
                    maxlength="8"
                    required
                  />
                  <label><input name="acknowledged" type="checkbox" value="true" />
                  I understand that disabling PIN protection lets this SIM be used without its PIN.</label>
                  <.button
                    type="submit"
                    variant="secondary"
                    disabled={!enabled?(@projection, "cellular.set_pin_lock")}
                  >Apply SIM PIN protection once</.button>
                </form>
              </div>
            </details>
        <% end %>
        <p :if={@cellular.operation} role="status">Cellular operation: {@cellular.operation}</p>
        <.notice :if={@cellular.error} tone="warning" role="alert">
          {@cellular.error.message}
        </.notice>
        <.setting_row :if={@cellular.supported} label="Saved SIM PIN">
          {saved_label(@cellular.pin_saved)}
        </.setting_row>
        <p :if={@cellular.supported} class="ui-help">{automatic_label(@cellular.auto_unlock)}</p>
        <.button
          :if={@cellular.supported and @cellular.pin_saved != false}
          phx-click="forget_pin"
          phx-target={@myself}
          variant="secondary"
          disabled={!enabled?(@projection, "cellular.forget_pin")}
        >
          Forget saved PIN (keep SIM protection)
        </.button>
        <p :if={@cellular.supported} class="ui-help">
          The PIN is stored on the device, not encrypted, and is included in full data-partition backups. It is never included in status or network settings exports. APN saved, SIM unlocked and Internet available are separate states.
        </p>
        <.notice :if={@message} role="status">{@message}</.notice>
      </.panel>
    </section>
    """
  end

  defp saved_label(true), do: "Stored on this device"
  defp saved_label(false), do: "Not stored"
  defp saved_label(_), do: "Unknown"

  defp automatic_label(:ready),
    do:
      "Automatic unlock is armed for this SIM. A failed or interrupted attempt blocks further automatic attempts across restarts."

  defp automatic_label(:blocked),
    do:
      "Automatic unlock is blocked. Check the SIM and explicitly unlock or verify its PIN; restarting will not retry it."

  defp automatic_label(:different_sim),
    do: "The saved PIN belongs to another SIM. It will not be sent to this SIM."

  defp automatic_label(:identity_unknown),
    do:
      "SIM identity could not be verified. Automatic unlock will not send a PIN until this modem can identify the same SIM, including while PIN-locked."

  defp automatic_label(:off), do: "Automatic unlock is off."
  defp automatic_label(_), do: "Automatic unlock status is unknown."

  defp enabled?(projection, key), do: get_in(projection, [:actions, key, :enabled]) == true
  defp sim_label(:ready), do: "Ready"
  defp sim_label(:absent), do: "No SIM detected"
  defp sim_label(:pin_required), do: "PIN required"
  defp sim_label(:puk_required), do: "PUK required — contact your carrier"
  defp sim_label(:pin2_required), do: "PIN2 required"
  defp sim_label(:puk2_required), do: "PUK2 required"
  defp sim_label(_), do: "Unknown — refresh status"
  defp lock_label(:enabled), do: "Enabled"
  defp lock_label(:disabled), do: "Disabled"
  defp lock_label(_), do: "Unknown"
  defp registration_label(:registered_home), do: "Registered (home)"
  defp registration_label(:registered_roaming), do: "Registered (roaming)"
  defp registration_label(:searching), do: "Searching"
  defp registration_label(:registration_denied), do: "Denied"
  defp registration_label(:not_registered), do: "Not registered"
  defp registration_label(_), do: "Unknown"
end

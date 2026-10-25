defmodule NervesGateWeb.CellularPanel do
  @moduledoc "SIM readiness and exceptional manual settings. Forms belong to the network editor."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:projection, :map, required: true)
  attr(:target, :any, required: true)
  attr(:generation, :integer, default: 0)
  attr(:settings, :boolean, default: false)
  attr(:connect, :boolean, default: false)
  attr(:custom, :boolean, default: false)
  attr(:apn, :string, default: "")

  def sim(assigns) do
    assigns =
      assign(
        assigns,
        :cellular,
        Map.merge(NervesGate.Cellular.view(nil), assigns.projection.cellular)
      )

    assigns = assign(assigns, :interface, get_in(assigns.projection, [:connections, :cellular]))

    ~H"""
    <section id="cellular-panel" class="ui-stack" aria-label="SIM setup">
      <.panel title="SIM" icon="internet">
        <%= cond do %>
          <% !@cellular.supported -> %>
            <p>This device does not support 4G.</p>
          <% @cellular.present != true -> %>
            <p>No 4G modem detected.</p>
          <% @cellular.sim == :pin_required -> %>
            <form
              id={"cellular-unlock-#{@generation}"}
              phx-submit={if @connect, do: "unlock-connect", else: "unlock"}
              phx-target={@target}
              phx-auto-recover="ignore"
              class="ui-stack"
            >
              <label for="cellular-pin">SIM PIN</label>
              <input
                id="cellular-pin"
                name="pin"
                type="password"
                inputmode="numeric"
                pattern="[0-9]{4,8}"
                minlength="4"
                maxlength="8"
                required
                autocomplete="off"
              />
              <p class="ui-help">
                {@cellular.pin_attempts_remaining || "Unknown"} attempts remaining. Incorrect PINs consume attempts. After a successful unlock, the PIN is remembered privately for this SIM.
              </p>
              <.button
                type="submit"
                phx-disable-with="Unlocking…"
                disabled={!enabled?(@projection, "cellular.unlock")}
              >{if @connect, do: "Unlock and connect", else: "Unlock SIM"}</.button>
            </form>
          <% @cellular.sim == :ready -> %>
            <p id="sim-ready">
              SIM ready<span :if={@cellular.provider}> · {@cellular.provider.name}</span>
            </p>
          <% @cellular.sim == :absent -> %>
            <p>Insert your SIM to continue.</p>
          <% @cellular.sim in [:puk_required, :pin2_required, :puk2_required] -> %>
            <.notice tone="warning">
              This SIM needs recovery with your carrier or a phone. Do not guess a PIN or PUK.
            </.notice>
          <% true -> %>
            <p role="status">Checking SIM…</p>
        <% end %>
        <p :if={@cellular.operation != nil} role="status">{working_label(@cellular.operation)}</p>
        <.notice :if={@cellular.error != nil} tone="warning" role="alert">
          {@cellular.error.message}
        </.notice>
        <.notice
          :if={@cellular.error == nil and @cellular.result != nil and @cellular.result.error != nil}
          tone="warning"
          role="alert"
        >
          {@cellular.result.error.message}
        </.notice>
        <.button
          :if={
            @cellular.sim in [:unknown, :absent] and @cellular.operation == nil and
              @cellular.present == true
          }
          phx-click="refresh"
          phx-target={@target}
          variant="secondary"
          disabled={!enabled?(@projection, "cellular.refresh")}
        >Check SIM again</.button>
        <div :if={@settings and @cellular.present == true} class="ui-stack">
          <.setting_row label="PIN protection">{lock_label(@cellular.pin_lock)}</.setting_row>
          <.setting_row label="Saved PIN">{saved_label(@cellular.pin_saved)}</.setting_row>
          <p :if={@cellular.pin_lock == :disabled} class="ui-help">No unlock PIN is required.</p>
          <p :if={@cellular.auto_unlock == :blocked} class="ui-help">
            Automatic unlock is blocked. Restarting will not retry a PIN.
          </p>
          <form
            :if={
              @cellular.sim == :ready and @cellular.pin_lock == :enabled and
                @cellular.auto_unlock != :ready
            }
            id={"cellular-remember-#{@generation}"}
            phx-submit="save_pin"
            phx-target={@target}
            phx-auto-recover="ignore"
            class="ui-stack"
          >
            <label for="cellular-remember-pin">Current SIM PIN</label>
            <input
              id="cellular-remember-pin"
              name="pin"
              type="password"
              inputmode="numeric"
              pattern="[0-9]{4,8}"
              minlength="4"
              maxlength="8"
              required
              autocomplete="off"
            />
            <p class="ui-help">
              Verify once and remember the existing PIN. Protection stays enabled. A wrong PIN consumes an attempt.
            </p>
            <.button
              type="submit"
              phx-disable-with="Verifying…"
              disabled={!enabled?(@projection, "cellular.save_pin")}
            >Remember PIN</.button>
          </form>
          <.button
            :if={@cellular.pin_saved != false}
            phx-click="forget_pin"
            phx-target={@target}
            variant="secondary"
            disabled={!enabled?(@projection, "cellular.forget_pin")}
          >Forget saved PIN</.button>
          <p class="ui-help">
            Remembered PINs are stored on the device, not encrypted. PIN changes and protection controls are available through the administrative API.
          </p>
        </div>
      </.panel>
      <.panel :if={@settings} title="4G connection" icon="internet">
        <.setting_row label="Registration">{registration_label(@cellular.registration)}</.setting_row>
        <.setting_row label="Operator">{text(@cellular.operator)}</.setting_row>
        <.setting_row label="Radio">{text(@cellular.access_technology)}</.setting_row>
        <.setting_row label="Signal">
          {if is_integer(@cellular.signal_dbm), do: "#{@cellular.signal_dbm} dBm", else: "Unknown"}
        </.setting_row>
        <.setting_row label="Carrier profile APN">
          {if @cellular.provider, do: @cellular.provider.apn, else: "Not identified"}
        </.setting_row>
        <.setting_row label="Internet">
          {NervesGateWeb.NetworkStatus.connection_label(
            @interface && Map.get(@interface, :connection)
          )}
        </.setting_row>
        <.setting_row label="IP addresses">
          <code :for={ip <- (@interface && Map.get(@interface, :addresses, [])) || []}>{ip.address}/{ip.prefix_length}</code>
          <span :if={@interface == nil or Map.get(@interface, :addresses, []) == []}>Not assigned</span>
        </.setting_row>
        <.button
          phx-click="reconnect"
          phx-target={@target}
          variant="secondary"
          disabled={!enabled?(@projection, "cellular.reconnect")}
          data-confirm="Reconnect 4G? Cellular traffic and remote access may disconnect. PIN protection will not change."
        >Reconnect 4G</.button>
      </.panel>
      <.panel
        :if={@settings and @custom and @cellular.supported and @cellular.present == true}
        title="Private APN credentials"
        icon="lock"
      >
        <p class="ui-help">
          Only for a private or unlisted plan that requires PAP. Carrier presets already include public defaults. These credentials are not your SIM PIN.
        </p>
        <.setting_row label="Saved authentication">{authentication_label(@cellular)}</.setting_row>
        <form
          id={"cellular-authentication-#{@generation}"}
          phx-submit="save_authentication"
          phx-target={@target}
          phx-auto-recover="ignore"
          class="ui-stack"
        >
          <.setting_row label="APN">
            {if @apn == "", do: "Enter the APN above", else: @apn}
          </.setting_row>
          <input type="hidden" name="apn" value={@apn} />
          <label for="cellular-auth-username">PAP username</label>
          <input
            id="cellular-auth-username"
            name="username"
            maxlength="64"
            required
            autocomplete="off"
          />
          <label for="cellular-auth-password">PAP password</label>
          <input
            id="cellular-auth-password"
            name="password"
            type="password"
            maxlength="64"
            autocomplete="off"
          />
          <p class="ui-help">
            Saved separately from network settings, not encrypted. Saving does not reconnect or participate in rollback. Apply the matching APN afterwards, or reconnect if it is already applied.
          </p>
          <.button
            type="submit"
            phx-disable-with="Saving…"
            disabled={@apn == "" or !enabled?(@projection, "cellular.save_authentication")}
          >Save private credentials</.button>
        </form>
        <.button
          :if={@cellular.authentication != :none}
          phx-click="forget_authentication"
          phx-target={@target}
          variant="secondary"
          disabled={!enabled?(@projection, "cellular.forget_authentication")}
        >Forget private credentials</.button>
      </.panel>
    </section>
    """
  end

  def result_message(%{error: %{message: message}}), do: message

  def result_message(%{operation: :reconnect}),
    do: "Reconnecting 4G. Internet availability is checked separately."

  def result_message(%{operation: operation})
      when operation in [:unlock, :auto_unlock, :save_pin], do: "SIM PIN verified and remembered."

  def result_message(%{operation: :save_authentication}),
    do: "Private APN credentials saved. Apply the matching APN or reconnect 4G."

  def result_message(%{operation: :forget_authentication}), do: "Private APN credentials removed."

  def result_message(%{operation: :forget_pin}),
    do: "Saved PIN removed; SIM protection is unchanged."

  def result_message(_), do: "Cellular operation completed."
  defp working_label(operation) when operation in [:unlock, :auto_unlock], do: "Unlocking SIM…"
  defp working_label(:reconnect), do: "Reconnecting 4G…"
  defp working_label(_), do: "Checking SIM…"
  defp enabled?(projection, key), do: get_in(projection, [:actions, key, :enabled]) == true
  defp saved_label(true), do: "Remembered on this device"
  defp saved_label(false), do: "Not remembered"
  defp saved_label(_), do: "Unknown"
  defp lock_label(:enabled), do: "Enabled"
  defp lock_label(:disabled), do: "Disabled"
  defp lock_label(_), do: "Unknown"

  defp text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: "Unknown", else: value)

  defp text(_), do: "Unknown"

  defp authentication_label(%{authentication: :pap, authentication_apn: apn}),
    do: "PAP for #{apn}"

  defp authentication_label(%{authentication: :none}), do: "None"
  defp authentication_label(_), do: "Unknown"
  defp registration_label(:registered_home), do: "Registered"
  defp registration_label(:registered_roaming), do: "Registered (roaming)"
  defp registration_label(:searching), do: "Searching"
  defp registration_label(:registration_denied), do: "Denied"
  defp registration_label(:not_registered), do: "Not registered"
  defp registration_label(_), do: "Unknown"
end

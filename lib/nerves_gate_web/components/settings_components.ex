defmodule NervesGateWeb.SettingsComponents do
  @moduledoc "Presentation for guarded post-commissioning configuration changes."

  use NervesGateWeb, :html

  import NervesGateWeb.GatewayComponents

  attr(:view, :map, required: true)
  attr(:settings, :map, required: true)

  def change_guard(assigns) do
    ~H"""
    <.card :if={@settings.pending} class="border-amber-400/25 bg-amber-400/[0.06]">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="text-xs font-bold uppercase tracking-[0.18em] text-amber-300">
            Unconfirmed {kind_label(@settings.pending.kind)} change
          </p>
          <h2 class="mt-2 text-xl font-semibold text-white">
            {phase_label(@settings.pending.phase)}
          </h2>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-300">
            The previous configuration remains the persisted known-good version. This candidate
            is reverted automatically unless it is confirmed from a fresh management connection.
          </p>
          <p :if={@settings.pending.remaining_seconds} class="mt-2 font-mono text-sm text-amber-200">
            Rollback in {duration(@settings.pending.remaining_seconds)}
          </p>
        </div>
        <.badge tone={:warning}>{@settings.pending.phase}</.badge>
      </div>

      <div :if={@settings.pending.phase == :awaiting_confirmation} class="mt-5 flex flex-wrap gap-3">
        <.button
          :if={@settings.pending.confirmable}
          phx-click="confirm-settings"
          phx-value-id={@settings.pending.id}
        >
          Keep changes
        </.button>
        <.link_button :if={!@settings.pending.confirmable} href="/settings">
          Reconnect to confirm
        </.link_button>
        <.button
          phx-click="revert-settings"
          phx-value-id={@settings.pending.id}
          tone={:danger}
        >
          Revert now
        </.button>
      </div>
    </.card>

    <.card :if={!@settings.pending and @settings.last_error} class="border-amber-400/20">
      <p class="text-sm text-amber-100">
        Last guarded change: {humanize(@settings.last_error)}. The persisted configuration is active.
      </p>
    </.card>
    """
  end

  attr(:view, :map, required: true)
  attr(:disabled, :boolean, default: false)

  def forms(assigns) do
    ~H"""
    <fieldset disabled={@disabled} class="grid gap-6 disabled:opacity-60">
      <.card>
        <.section_header
          eyebrow="Guarded change"
          title="Internet uplink"
          description="The candidate must pass link, route, DNS, and HTTPS checks before remote confirmation is offered."
        />
        <div class="mt-4 grid gap-1 text-sm text-zinc-400 sm:grid-cols-2">
          <p>Persisted method: <span class="text-zinc-200">{network_method(@view)}</span></p>
          <p>Interface: <span class="font-mono text-zinc-200">{network_value(@view, :interface) || "Unavailable"}</span></p>
        </div>
        <form phx-submit="stage-internet" class="mt-5 grid gap-4">
          <label class="grid gap-2 text-sm font-medium text-zinc-300">
            <span>Addressing</span>
            <select
              id="settings-internet-method"
              name="internet[method]"
              aria-controls="settings-static-internet-fields"
              aria-expanded={to_string(network_method(@view) == :static)}
              data-internet-method
              phx-hook="InternetMethod"
              class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70"
            >
              <option value="dhcp" selected={network_method(@view) == :dhcp}>DHCP (automatic)</option>
              <option value="static" selected={network_method(@view) == :static}>Static IPv4</option>
            </select>
          </label>
          <div
            id="settings-static-internet-fields"
            data-static-internet-fields
            hidden={network_method(@view) != :static}
            class="grid gap-4 sm:grid-cols-2"
          >
            <.input label="IP address" name="internet[ip_address]" value={network_value(@view, :address)} />
            <.input label="Prefix length" name="internet[prefix_length]" value={network_value(@view, :prefix_length)} />
            <.input label="Gateway" name="internet[gateway]" value={network_value(@view, :gateway)} />
            <.input label="DNS resolver" name="internet[dns]" value={network_value(@view, :dns_primary)} />
          </div>
          <.button type="submit" phx-disable-with="Applying and validating…">
            Test Internet candidate
          </.button>
        </form>
      </.card>

      <.card>
        <.section_header
          eyebrow="Guarded change"
          title="Tailnet enrollment"
          description="A temporary Tailscale account profile is selected. The previous profile is restored unless the new path is confirmed."
        />
        <div class="mt-4 grid gap-1 text-sm text-zinc-400 sm:grid-cols-2">
          <p>Hostname: <span class="text-zinc-200">{@view.tailnet.hostname || "Unavailable"}</span></p>
          <p>IPv4: <span class="font-mono text-zinc-200">{@view.tailnet.ipv4 || "Unavailable"}</span></p>
        </div>
        <form phx-submit="stage-tailnet" class="mt-5 grid gap-4">
          <.input
            label="Candidate Tailscale auth key"
            name="auth_token"
            type="password"
            autocomplete="off"
            required
            hint="Used once for the temporary profile and never written to the settings journal."
          />
          <.button type="submit" phx-disable-with="Switching Tailnet profile…">
            Test Tailnet candidate
          </.button>
        </form>
      </.card>

      <.card>
        <.section_header
          eyebrow="Guarded change"
          title="Cluster group"
          description="Cluster groups are public within the Tailnet. Select a discovered group, create one, or leave blank for singular mode."
        />
        <dl class="mt-4 grid grid-cols-[8rem_1fr] gap-2 text-sm">
          <dt class="text-zinc-500">Current group</dt>
          <dd class="text-zinc-200">{@view.cluster.group || "Singular"}</dd>
          <dt class="text-zinc-500">Connected</dt>
          <dd class="text-zinc-200">{length(@view.cluster.connected)}</dd>
        </dl>
        <form phx-submit="stage-cluster" class="mt-5 grid gap-4">
          <.input
            label="Candidate cluster group"
            name="cluster[group]"
            value={@view.cluster.group}
            list="settings-cluster-groups"
            maxlength="128"
            pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
            hint="Public group name; blank selects singular mode."
          />
          <datalist id="settings-cluster-groups">
            <option :for={group <- @view.cluster.groups} value={group.name}>
              {group.members} visible gateway(s)
            </option>
          </datalist>
          <.button type="submit" phx-disable-with="Testing cluster group…">
            Test cluster candidate
          </.button>
        </form>

        <div class="mt-5 border-t border-white/8 pt-4">
          <h3 class="text-sm font-semibold text-zinc-200">Available Tailnet groups</h3>
          <p :if={@view.cluster.groups == []} class="mt-2 text-sm text-zinc-500">
            No groups have been advertised by visible gateways.
          </p>
          <ul :if={@view.cluster.groups != []} class="mt-3 grid gap-2">
            <li
              :for={group <- @view.cluster.groups}
              class="flex items-center justify-between rounded-lg border border-white/8 px-3 py-2 text-sm"
            >
              <span class="font-medium text-zinc-200">{group.name}</span>
              <span class="text-zinc-500">{group.members} visible · {group.connected} connected</span>
            </li>
          </ul>
        </div>
      </.card>
    </fieldset>
    """
  end

  defp network_method(view), do: Map.get(network_config(view), :method, :dhcp)
  defp network_value(view, key), do: Map.get(network_config(view), key)

  defp network_config(view) do
    Map.get(view.network_configuration, :known_good) || %{}
  end

  defp kind_label(:internet), do: "Internet"
  defp kind_label(:tailnet), do: "Tailnet"
  defp kind_label(:cluster), do: "cluster"
  defp kind_label(kind), do: to_string(kind)

  defp phase_label(:applying), do: "Applying and validating candidate"
  defp phase_label(:awaiting_confirmation), do: "Reconnect, verify access, and keep the change"
  defp phase_label(:rolling_back), do: "Restoring persisted settings"
  defp phase_label(phase), do: humanize(phase)

  defp duration(seconds), do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp humanize(value) when is_atom(value) or is_binary(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize(value), do: inspect(value)
end

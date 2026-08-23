defmodule NervesGateWeb.StatusLive.Render do
  @moduledoc false

  use NervesGateWeb, :html

  import NervesGateWeb.GatewayComponents

  attr(:view, :map, required: true)
  attr(:flash, :map, required: true)

  def render(assigns) do
    ~H"""
    <.dashboard view={@view} flash={@flash} />
    """
  end

  attr(:view, :map, required: true)
  attr(:flash, :map, required: true)

  def dashboard(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen">
      <div class="mx-auto w-full max-w-7xl px-4 py-5 sm:px-6 sm:py-8">
        <header class="flex flex-col gap-5 border-b border-white/10 pb-6 lg:flex-row lg:items-center lg:justify-between">
          <div class="flex items-center gap-3">
            <span class="grid size-11 place-items-center rounded-2xl border border-emerald-400/20 bg-emerald-400/10 text-emerald-300">
              <.icon name={:network} class="size-6" />
            </span>
            <div>
              <p class="text-[11px] font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
              <h1 class="mt-0.5 text-xl font-semibold tracking-tight text-white">{@view.local.name}</h1>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2 sm:gap-3">
            <.link_button href={~p"/commissioning"}>Settings</.link_button>
            <div class="rounded-xl border border-white/8 bg-white/[0.025] px-3 py-2 text-right">
              <strong class="block text-sm text-zinc-200">{@view.local.hostname}</strong>
              <span class="block font-mono text-xs text-zinc-500">{@view.local.ipv4 || "No Tailnet IP"}</span>
            </div>
            <div class="flex items-center gap-2 rounded-xl border border-white/8 bg-white/[0.025] px-3 py-2">
              <.icon name={:users} class="size-4 text-zinc-400" />
              <strong class="text-sm text-zinc-200">{@view.people_count}</strong>
              <span class="hidden text-xs text-zinc-500 sm:inline">viewing</span>
            </div>
          </div>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <section class="mt-6 overflow-hidden rounded-2xl border border-white/10 bg-zinc-900/70 sm:grid sm:grid-cols-4">
          <.metric
            label="Known gateways"
            value={@view.metrics.known_gateways}
            icon={:server}
          />
          <.metric
            label="Currently online"
            value={@view.metrics.online_gateways}
            icon={:network}
            tone={if @view.metrics.online_gateways == @view.metrics.known_gateways, do: :good, else: :warning}
          />
          <.metric
            label="Connected peers"
            value={@view.metrics.connected_peers}
            icon={:users}
            tone={:good}
          />
          <.metric
            label="Known active alarms"
            value={@view.metrics.alarms}
            icon={:alert}
            tone={if @view.metrics.alarms == 0, do: :good, else: :bad}
          />
        </section>

        <div class="mt-6 grid gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
          <aside class="min-w-0">
            <.card class="lg:sticky lg:top-6">
              <.section_header
                eyebrow="Fleet"
                title="Gateway state"
                description="Select a gateway to inspect its replicated state."
              />
              <div class="mt-4">
                <.node_switcher nodes={@view.nodes} selected_id={@view.selected.id} />
              </div>
            </.card>
          </aside>

          <div class="grid min-w-0 gap-6">
            <.card>
              <.section_header
                eyebrow={if @view.selected.self, do: "This gateway", else: "Replicated gateway"}
                title={@view.selected.name}
                description={selected_description(@view.selected)}
              >
                <:action>
                  <.link_button
                    :if={not @view.selected.self and not is_nil(@view.selected.url) and @view.selected.connected}
                    href={@view.selected.url}
                  >
                    Open gateway <.icon name={:external} class="size-4" />
                  </.link_button>
                </:action>
              </.section_header>

              <div
                :if={@view.selected.stale}
                class="mt-4 flex items-start gap-3 rounded-xl border border-amber-400/20 bg-amber-400/8 px-4 py-3 text-sm text-amber-100"
              >
                <.icon name={:clock} class="mt-0.5 size-5 shrink-0" />
                <p>
                  Showing revision {@view.selected.revision}, last received
                  {last_seen(@view.selected.last_seen_at)}. This data remains available while this
                  surviving gateway stays online.
                </p>
              </div>

              <div class="mt-5">
                <.layer_flow layers={@view.selected.layers} />
              </div>
            </.card>

            <div class="grid gap-6 xl:grid-cols-2">
              <.card>
                <.section_header
                  eyebrow="Operations"
                  title="Active alarms"
                  description={alarm_description(@view.selected)}
                />
                <div class="mt-4">
                  <.alarm_list alarms={@view.selected.data.alarms} stale={@view.selected.stale} />
                </div>
              </.card>

              <.card>
                <.section_header
                  eyebrow="Identity"
                  title="Device details"
                  description="Canonical fields published by this gateway."
                />
                <div class="mt-5">
                  <.detail_list items={device_details(@view.selected)} />
                </div>
              </.card>
            </div>

            <.local_controls :if={@view.selected.self} view={@view} />
          </div>
        </div>
      </div>
    </main>
    """
  end

  attr(:view, :map, required: true)

  defp local_controls(assigns) do
    ~H"""
    <div class="grid gap-6 xl:grid-cols-2">
      <.card>
        <.section_header
          eyebrow="Local diagnostics"
          title="Internet checks"
          description="Detailed checks remain local and are not replicated."
        />
        <div class="mt-5">
          <.detail_list items={internet_details(@view.internet)} />
        </div>
      </.card>

      <.card>
        <.section_header
          eyebrow="Runtime"
          title="System"
          description="Local runtime diagnostics are deliberately not replicated."
        />
        <div class="mt-5">
          <.detail_list items={system_details(@view.diagnostics)} />
        </div>
      </.card>

      <.card class="xl:col-span-2">
        <.section_header
          eyebrow="Remote access"
          title="Remote IEx"
          description="NervesSSH listens only on this gateway's concrete Tailscale IPv4 address."
        >
          <:action>
            <.badge tone={ssh_tone(@view.ssh)}>{ssh_label(@view.ssh)}</.badge>
          </:action>
        </.section_header>

        <div class="mt-5 grid gap-5 xl:grid-cols-[minmax(0,1fr)_auto] xl:items-end">
          <.detail_list items={ssh_details(@view.ssh)} />
          <div class="flex flex-wrap gap-3">
            <.button
              :if={not @view.ssh.enabled}
              type="button"
              phx-click="enable-ssh"
              phx-disable-with="Enabling Remote IEx…"
              disabled={not is_nil(@view.configuration.pending)}
            >
              Enable Remote IEx
            </.button>
            <.button
              :if={@view.ssh.enabled}
              type="button"
              tone={:danger}
              phx-click="disable-ssh"
              phx-disable-with="Disabling Remote IEx…"
              disabled={not is_nil(@view.configuration.pending)}
            >
              Disable Remote IEx
            </.button>
          </div>
        </div>
      </.card>

      <.card class="xl:col-span-2">
        <.section_header
          eyebrow="Tailnet routing"
          title="Subnet router"
          description="Advertise local networks without changing this gateway's remote-management connection."
        >
          <:action>
            <.badge tone={subnet_router_tone(@view.subnet_router)}>
              {subnet_router_label(@view.subnet_router)}
            </.badge>
          </:action>
        </.section_header>

        <div class="mt-5 grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(18rem,0.7fr)]">
          <form id="subnet-router-form" phx-submit="enable-subnet-router" class="grid gap-4">
            <.input
              label="Advertised CIDRs"
              name="subnet_router[routes]"
              value={Enum.join(@view.subnet_router.routes, ", ")}
              placeholder="192.168.10.0/24, 10.20.0.0/16"
              required
              disabled={not is_nil(@view.configuration.pending)}
              hint="Separate multiple IPv4 or IPv6 networks with commas or spaces. Route approval remains controlled by Tailnet policy."
            />

            <div class="flex flex-wrap gap-3">
              <.button
                type="submit"
                disabled={not is_nil(@view.configuration.pending)}
                phx-disable-with="Applying routes…"
              >
                {if @view.subnet_router.enabled, do: "Update routes", else: "Enable subnet router"}
              </.button>
              <.button
                :if={@view.subnet_router.enabled}
                type="button"
                tone={:danger}
                phx-click="disable-subnet-router"
                phx-disable-with="Withdrawing routes…"
                data-confirm="Withdraw all advertised subnet routes? Remote access to this gateway will remain available."
                disabled={not is_nil(@view.configuration.pending)}
              >
                Disable subnet router
              </.button>
            </div>

            <p
              :if={not is_nil(@view.configuration.pending)}
              class="text-sm leading-6 text-amber-200"
            >
              Subnet routing can be changed after the remote-access configuration is accepted or rejected.
            </p>
          </form>

          <.detail_list items={subnet_router_details(@view.subnet_router)} />
        </div>
      </.card>
    </div>
    """
  end

  defp selected_description(node) do
    if node.stale,
      do: "Last-known public state retained after the gateway disconnected.",
      else: "Live public state at revision #{node.revision}."
  end

  defp alarm_description(node) do
    count = length(node.data.alarms)
    suffix = if node.stale, do: " in the last-known state", else: ""
    "#{count} actionable alarm#{if count == 1, do: "", else: "s"}#{suffix}."
  end

  defp device_details(node) do
    [
      {"Machine ID", node.id},
      {"Tailnet hostname", node.data.tailnet.hostname || "Unavailable"},
      {"Tailnet IPv4", node.data.tailnet.ipv4 || "Unavailable"},
      {"Cluster group", node.data.cluster.group || "Singular"},
      {"Subnet router", humanize(node.data.subnet_router.status)},
      {"Subnet routes", route_list(node.data.subnet_router.routes)},
      {"Advertised routes", route_list(node.data.subnet_router.advertised)},
      {"Approved routes", route_list(node.data.subnet_router.approved)},
      {"Primary routes", route_list(node.data.subnet_router.primary)},
      {"Remote IEx", ssh_label(node.data.ssh)},
      {"SSH address", ssh_address(node.data.ssh)},
      {"BEAM node", format_node(node.data.cluster.node)},
      {"Firmware", node.data.firmware_version},
      {"Revision", node.revision},
      {"Connection", if(node.connected, do: "Connected", else: "Stale")}
    ]
  end

  defp internet_details(internet) do
    checks = Map.get(internet, :checks, %{})

    [
      {"Interface", Map.get(internet, :interface) || "Not configured"},
      {"Physical link", check_value(checks, :physical_link)},
      {"IP address", check_value(checks, :ip_address)},
      {"Default route", check_value(checks, :default_route)},
      {"DNS", check_value(checks, :dns)},
      {"HTTPS", check_value(checks, :internet_https)}
    ]
  end

  defp system_details(diagnostics) do
    [
      {"Target", diagnostics.target},
      {"OTP release", diagnostics.otp_release},
      {"Uptime", duration(diagnostics.uptime_seconds)},
      {"Memory", "#{megabytes(diagnostics.memory_bytes)} MB"}
    ]
  end

  defp subnet_router_details(subnet_router) do
    [
      {"Configured", route_list(subnet_router.routes)},
      {"Advertised", route_list(subnet_router.advertised)},
      {"Approved", route_list(subnet_router.approved)},
      {"Primary", route_list(subnet_router.primary)}
    ]
  end

  defp ssh_details(ssh) do
    [
      {"SSH", if(ssh.enabled, do: "Enabled ●", else: "○ Disabled")},
      {"Status", ssh_label(ssh)},
      {"Address", ssh_address(ssh)},
      {"Access", "Tailnet only"}
    ]
  end

  defp ssh_tone(%{state: :listening}), do: :good
  defp ssh_tone(%{state: :disabled}), do: :neutral
  defp ssh_tone(_ssh), do: :warning

  defp ssh_label(%{state: :waiting_for_tailnet}), do: "Waiting for Tailnet"
  defp ssh_label(%{state: state}), do: humanize(state)

  defp ssh_address(%{address: nil}), do: "Unavailable"

  defp ssh_address(%{address: address, port: port}) do
    "#{address |> :inet.ntoa() |> to_string()}:#{port}"
  end

  defp subnet_router_tone(%{status: :disabled}), do: :neutral
  defp subnet_router_tone(%{status: :online}), do: :good
  defp subnet_router_tone(_subnet_router), do: :warning

  defp subnet_router_label(%{status: :disabled}), do: "Disabled"
  defp subnet_router_label(%{status: :online}), do: "Advertising"
  defp subnet_router_label(%{status: :blocked}), do: "Blocked"
  defp subnet_router_label(_subnet_router), do: "Needs attention"

  defp route_list([]), do: "None"
  defp route_list(routes), do: Enum.join(routes, ", ")

  defp check_value(checks, key) do
    case Map.get(checks, key, :unknown) do
      :ok -> "OK"
      :unknown -> "Unknown"
      {:error, reason} -> humanize(reason)
      other -> humanize(other)
    end
  end

  defp format_node(nil), do: "Disabled"
  defp format_node(node), do: to_string(node)

  defp last_seen(nil), do: "at an unknown time"
  defp last_seen(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  defp megabytes(bytes), do: Float.round(bytes / 1_048_576, 1)
end

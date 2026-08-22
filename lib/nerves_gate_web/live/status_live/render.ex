defmodule NervesGateWeb.StatusLive.Render do
  @moduledoc false

  use NervesGateWeb, :html

  import NervesGateWeb.GatewayComponents
  import NervesGateWeb.SetupComponents

  attr(:view, :map, required: true)
  attr(:tailnet_access, :boolean, required: true)
  attr(:flash, :map, required: true)

  def render(assigns) do
    ~H"""
    <.current
      :if={!@view.setup.ready or !@tailnet_access}
      view={@view}
      flash={@flash}
    />
    <.dashboard
      :if={@view.setup.ready and @tailnet_access}
      view={@view}
      flash={@flash}
    />
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
          eyebrow="Local configuration"
          title="Device name"
          description="Saved atomically in /data/device.json and replicated as public state."
        />
        <form phx-submit="rename-device" class="mt-5 grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
          <.input
            label="Display name"
            name="device[name]"
            value={@view.profile["name"]}
            maxlength="80"
            required
          />
          <.button type="submit">Save name</.button>
        </form>
        <div class="mt-5 border-t border-white/8 pt-5">
          <.detail_list items={profile_details(@view)} />
        </div>
      </.card>

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

      <.card class="border-rose-400/15">
        <.section_header
          eyebrow="Local access"
          title="Recovery network"
          description="Re-enable isolated commissioning access without deleting saved Internet or Tailnet state."
        />
        <.button phx-click="enable-recovery" tone={:danger} class="mt-5 w-full">
          <.icon name={:shield} class="size-4" /> Enable recovery access
        </.button>
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
      {"BEAM node", format_node(node.data.cluster.node)},
      {"Firmware", node.data.firmware_version},
      {"Revision", node.revision},
      {"Connection", if(node.connected, do: "Connected", else: "Stale")}
    ]
  end

  defp profile_details(view) do
    [
      {"System hostname", view.identity.hostname},
      {"Last changed", view.profile["updated_at"] || "Never"},
      {"Changed by", changed_by(view.profile["updated_by"])}
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

  defp check_value(checks, key) do
    case Map.get(checks, key, :unknown) do
      :ok -> "OK"
      :unknown -> "Unknown"
      {:error, reason} -> humanize(reason)
      other -> humanize(other)
    end
  end

  defp changed_by(nil), do: "Never"
  defp changed_by(%{"name" => name, "ip" => nil}), do: name
  defp changed_by(%{"name" => name, "ip" => ip}), do: "#{name} · #{ip}"
  defp changed_by(_actor), do: "Unknown"

  defp format_node(nil), do: "Disabled"
  defp format_node(node), do: to_string(node)

  defp last_seen(nil), do: "at an unknown time"
  defp last_seen(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  defp megabytes(bytes), do: Float.round(bytes / 1_048_576, 1)
end

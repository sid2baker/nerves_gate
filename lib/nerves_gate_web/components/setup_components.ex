defmodule NervesGateWeb.SetupComponents do
  @moduledoc "Reusable commissioning flow components."

  use NervesGateWeb, :html

  attr(:view, :map, required: true)
  attr(:flash, :map, required: true)

  def current(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen">
      <div class="mx-auto w-full max-w-5xl px-4 py-8 sm:px-6 sm:py-14">
        <header class="flex flex-col gap-5 border-b border-white/10 pb-8 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-[-0.04em] text-white sm:text-5xl">
              Initialize this gateway
            </h1>
            <p class="mt-3 max-w-2xl text-sm leading-6 text-zinc-400">
              Complete one verified step at a time. Persistent settings remain readable under
              <code class="text-emerald-300">/data</code>.
            </p>
          </div>
          <.badge tone={:info}>{phase_label(@view.setup.phase)}</.badge>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <ol class="mt-8 grid grid-cols-4 gap-1" aria-label="Initialization progress">
          <li
            :for={{phase, index} <- Enum.with_index(phases(), 1)}
            class={[
              "border-b-2 px-1 pb-3 text-center text-[10px] font-bold uppercase tracking-wider sm:text-xs",
              if(step_complete?(@view.setup.phase, phase),
                do: "border-emerald-400 text-emerald-300",
                else: "border-white/10 text-zinc-600"
              )
            ]}
          >
            <span class="hidden sm:inline">{index}. </span>{phase_label(phase)}
          </li>
        </ol>

        <div class="mx-auto mt-8 max-w-2xl">
          <.internet_step :if={@view.setup.phase in [:internet, :recovery]} />
          <.tailnet_step :if={@view.setup.phase == :tailscale} />
          <.cluster_step :if={@view.setup.phase == :cluster} view={@view} />
          <.ready_step :if={@view.setup.phase == :ready} view={@view} />
        </div>
      </div>
    </main>
    """
  end

  defp internet_step(assigns) do
    ~H"""
    <.card class="relative overflow-hidden p-6 sm:p-8">
      <span class="absolute top-5 right-6 text-5xl font-black text-white/[0.035]">01</span>
      <.step_heading title="Connect to the Internet">
        DHCP is the default. Static settings become authoritative only after link, address,
        route, DNS, and HTTPS verification succeed.
      </.step_heading>
      <form phx-submit="configure-internet" class="mt-6 grid gap-4">
        <label class="grid gap-2 text-sm font-medium text-zinc-300">
          <span>Addressing</span>
          <select
            id="internet-method"
            name="internet[method]"
            aria-controls="static-internet-fields"
            aria-expanded="false"
            data-internet-method
            phx-hook="InternetMethod"
            class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70 focus:ring-3 focus:ring-emerald-400/10"
          >
            <option value="dhcp">DHCP (automatic)</option>
            <option value="static">Static IPv4</option>
          </select>
        </label>
        <p class="text-xs leading-5 text-zinc-500">
          DHCP obtains the IP address, subnet, gateway, and DNS settings automatically.
        </p>
        <div
          id="static-internet-fields"
          data-static-internet-fields
          hidden
          class="grid gap-4 sm:grid-cols-2"
        >
          <.input label="IP address" name="internet[ip_address]" placeholder="192.0.2.20" />
          <.input label="Prefix length" name="internet[prefix_length]" placeholder="24" />
          <.input label="Gateway" name="internet[gateway]" placeholder="192.0.2.1" />
          <.input label="DNS resolver" name="internet[dns]" placeholder="1.1.1.1" />
        </div>
        <.button
          type="submit"
          phx-disable-with="Verifying Internet…"
          class="mt-2 w-full"
        >
          Verify and save Internet
        </.button>
      </form>
    </.card>
    """
  end

  defp tailnet_step(assigns) do
    ~H"""
    <.card class="relative overflow-hidden p-6 sm:p-8">
      <span class="absolute top-5 right-6 text-5xl font-black text-white/[0.035]">02</span>
      <.step_heading title="Join the tailnet">
        The auth key is passed directly to Tailscale for enrollment and is never persisted,
        logged, or added to replicated device state.
      </.step_heading>
      <form phx-submit="configure-tailscale" class="mt-6 grid gap-4">
        <.input
          label="Tailscale auth key"
          name="auth_token"
          type="password"
          autocomplete="off"
          required
          hint="Use a scoped, reusable or ephemeral key appropriate for this gateway."
        />
        <.button type="submit" class="w-full">Join tailnet</.button>
      </form>
    </.card>
    """
  end

  attr(:view, :map, required: true)

  defp cluster_step(assigns) do
    ~H"""
    <.card class="relative overflow-hidden p-6 sm:p-8">
      <span class="absolute top-5 right-6 text-5xl font-black text-white/[0.035]">03</span>
      <.step_heading title="Choose cluster mode">
        Leave the group blank for singular mode, join a visible group, or create a new public
        group name. Gateways in the same Tailnet group connect automatically.
      </.step_heading>
      <dl class="mt-6 grid grid-cols-[8rem_1fr] gap-3 rounded-xl border border-white/8 bg-zinc-950/50 p-4 text-sm">
        <dt class="text-zinc-500">Tailnet name</dt>
        <dd class="truncate text-zinc-200">{@view.local.data.tailnet.hostname || "Connected"}</dd>
        <dt class="text-zinc-500">Tailnet IP</dt>
        <dd class="font-mono text-zinc-200">{@view.local.data.tailnet.ipv4 || "Detecting…"}</dd>
      </dl>
      <form phx-submit="configure-cluster" class="mt-5 grid gap-4">
        <.input
          label="Cluster group"
          name="cluster[group]"
          list="commissioning-cluster-groups"
          maxlength="128"
          pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
          hint="Public group name. Select a visible group, enter a new name, or leave blank for singular mode."
        />
        <datalist id="commissioning-cluster-groups">
          <option :for={group <- @view.cluster.groups} value={group.name}>
            {group.members} visible gateway(s)
          </option>
        </datalist>
        <div :if={@view.cluster.groups != []} class="rounded-xl border border-white/8 bg-zinc-950/40 p-4">
          <p class="text-xs font-bold uppercase tracking-wider text-zinc-500">Available groups</p>
          <ul class="mt-2 grid gap-2 text-sm">
            <li :for={group <- @view.cluster.groups} class="flex justify-between gap-3 text-zinc-300">
              <span class="font-medium">{group.name}</span>
              <span class="text-zinc-500">{group.members} visible</span>
            </li>
          </ul>
        </div>
        <.button type="submit" class="w-full">Complete and persist setup</.button>
      </form>
    </.card>
    """
  end

  attr(:view, :map, required: true)

  defp ready_step(assigns) do
    ~H"""
    <.card class="p-8 text-center sm:p-12">
      <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-emerald-400/10 text-emerald-300">
        <.icon name={:check} class="size-7" />
      </span>
      <h2 class="mt-5 text-2xl font-semibold text-white">Gateway ready</h2>
      <p class="mx-auto mt-2 max-w-md text-sm leading-6 text-zinc-400">
        Management is now restricted to the tailnet. Open the dashboard from a connected device.
      </p>
      <.link_button
        :if={@view.local.url}
        href={@view.local.url}
        class="mt-6"
      >
        Open dashboard <.icon name={:external} class="size-4" />
      </.link_button>
    </.card>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp step_heading(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-bold uppercase tracking-[0.18em] text-emerald-400">Current step</p>
      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-white">{@title}</h2>
      <p class="mt-2 max-w-xl text-sm leading-6 text-zinc-400">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  defp phases, do: [:internet, :tailscale, :cluster, :ready]

  defp step_complete?(current, phase) do
    current_index = Enum.find_index(phases(), &(&1 == current)) || 0
    phase_index = Enum.find_index(phases(), &(&1 == phase))
    phase_index <= current_index
  end

  defp phase_label(:recovery), do: "Internet recovery"
  defp phase_label(phase), do: phase |> to_string() |> String.capitalize()
end

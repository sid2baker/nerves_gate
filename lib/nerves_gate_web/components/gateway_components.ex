defmodule NervesGateWeb.GatewayComponents do
  @moduledoc "Reusable components for gateway fleet and device-state views."

  use NervesGateWeb, :html

  attr(:eyebrow, :string, required: true)
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  slot(:action)

  def section_header(assigns) do
    ~H"""
    <header class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p class="text-xs font-bold uppercase tracking-[0.18em] text-zinc-500">{@eyebrow}</p>
        <h2 class="mt-1 text-xl font-semibold tracking-tight text-white">{@title}</h2>
        <p :if={@description} class="mt-1 max-w-2xl text-sm leading-6 text-zinc-400">
          {@description}
        </p>
      </div>
      <div :if={@action != []}>{render_slot(@action)}</div>
    </header>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:icon, :atom, required: true)
  attr(:tone, :atom, default: :neutral)

  def metric(assigns) do
    ~H"""
    <article class="flex min-w-0 items-center gap-3 border-b border-white/8 p-4 last:border-b-0 sm:border-r sm:border-b-0 sm:last:border-r-0">
      <span class={["grid size-10 shrink-0 place-items-center rounded-xl", metric_icon_classes(@tone)]}>
        <.icon name={@icon} class="size-5" />
      </span>
      <span class="min-w-0">
        <span class="block truncate text-xs font-medium text-zinc-500">{@label}</span>
        <strong class="mt-0.5 block text-xl font-semibold text-white">{@value}</strong>
      </span>
    </article>
    """
  end

  attr(:nodes, :list, required: true)
  attr(:selected_id, :string, required: true)

  def node_switcher(assigns) do
    ~H"""
    <div class="grid gap-2" role="list" aria-label="Known gateways">
      <button
        :for={node <- @nodes}
        type="button"
        phx-click="select-node"
        phx-value-device-id={node.id}
        class={[
          "group flex w-full items-center gap-3 rounded-xl border px-3 py-3 text-left transition",
          if(node.id == @selected_id,
            do: "border-emerald-400/30 bg-emerald-400/10",
            else: "border-transparent bg-white/[0.025] hover:border-white/10 hover:bg-white/5"
          )
        ]}
      >
        <span class={["size-2.5 shrink-0 rounded-full", node_dot_classes(node.tone)]}></span>
        <span class="min-w-0 flex-1">
          <span class="flex items-center gap-2">
            <strong class="truncate text-sm text-zinc-100">{node.name}</strong>
            <span :if={node.self} class="text-[10px] font-bold uppercase tracking-wider text-emerald-300">
              This device
            </span>
          </span>
          <span class="mt-0.5 block truncate font-mono text-xs text-zinc-500">
            {node.ipv4 || "No Tailnet IP"}
          </span>
        </span>
        <.badge tone={node.tone}>{node.status}</.badge>
      </button>
    </div>
    """
  end

  attr(:layers, :list, required: true)

  def layer_flow(assigns) do
    ~H"""
    <div class="grid gap-2 sm:grid-cols-[1fr_auto_1fr_auto_1fr] sm:items-center">
      <%= for {layer, index} <- Enum.with_index(@layers) do %>
        <div class="rounded-xl border border-white/8 bg-zinc-950/55 p-4">
          <span class="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">{layer.name}</span>
          <div class="mt-2 flex items-center justify-between gap-2">
            <strong class="capitalize text-zinc-100">{layer.status}</strong>
            <.badge tone={layer.tone}>{layer.status}</.badge>
          </div>
          <p class="mt-2 truncate text-xs text-zinc-500">Observed: {layer.observed}</p>
        </div>
        <.icon
          :if={index < length(@layers) - 1}
          name={:network}
          class="mx-auto hidden size-4 text-zinc-600 sm:block"
        />
      <% end %>
    </div>
    """
  end

  attr(:alarms, :list, required: true)
  attr(:stale, :boolean, default: false)

  def alarm_list(assigns) do
    ~H"""
    <div>
      <div
        :if={@stale}
        class="mb-3 rounded-xl border border-amber-400/20 bg-amber-400/8 px-3 py-2 text-xs leading-5 text-amber-100"
      >
        This gateway is offline. These are its last successfully replicated alarms.
      </div>
      <div
        :if={@alarms == []}
        class="grid min-h-28 place-items-center rounded-xl border border-dashed border-white/10 text-center"
      >
        <div>
          <.icon name={:check} class="mx-auto size-6 text-emerald-400" />
          <p class="mt-2 text-sm font-medium text-zinc-300">No active alarms</p>
        </div>
      </div>
      <ul :if={@alarms != []} class="grid gap-2">
        <li
          :for={alarm <- @alarms}
          class="rounded-xl border border-rose-400/15 bg-rose-400/[0.06] px-4 py-3"
        >
          <div class="flex items-start gap-3">
            <.icon name={:alert} class="mt-0.5 size-5 shrink-0 text-rose-300" />
            <div class="min-w-0">
              <strong class="block break-all text-sm text-rose-100">{alarm.id}</strong>
              <p class="mt-1 text-sm leading-5 text-rose-200/70">{alarm.description}</p>
            </div>
            <.badge tone={alarm_tone(alarm.level)}>{alarm.level}</.badge>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr(:items, :list, required: true)

  def detail_list(assigns) do
    ~H"""
    <dl class="grid grid-cols-[minmax(7rem,0.7fr)_minmax(0,1.3fr)] gap-x-4 gap-y-3 text-sm">
      <%= for {label, value} <- @items do %>
        <dt class="text-zinc-500">{label}</dt>
        <dd class="min-w-0 break-words text-zinc-200">{value}</dd>
      <% end %>
    </dl>
    """
  end

  defp metric_icon_classes(:good), do: "bg-emerald-400/10 text-emerald-300"
  defp metric_icon_classes(:bad), do: "bg-rose-400/10 text-rose-300"
  defp metric_icon_classes(:warning), do: "bg-amber-400/10 text-amber-200"
  defp metric_icon_classes(_tone), do: "bg-white/5 text-zinc-300"

  defp node_dot_classes(:good), do: "bg-emerald-400 shadow-[0_0_0_4px_rgb(52_211_153_/_0.1)]"
  defp node_dot_classes(:bad), do: "bg-rose-400"
  defp node_dot_classes(:warning), do: "bg-amber-300"
  defp node_dot_classes(_tone), do: "bg-zinc-500"

  defp alarm_tone(level) when level in [:error, :critical, :alert, :emergency], do: :bad
  defp alarm_tone(:warning), do: :warning
  defp alarm_tone(_level), do: :neutral
end

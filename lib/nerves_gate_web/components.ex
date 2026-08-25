defmodule NervesGateWeb.CoreComponents do
  @moduledoc "Reusable presentation-only components shared by gateway views."

  use Phoenix.Component

  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <section class={[
      "rounded-2xl border border-white/10 bg-zinc-900/75 p-5 shadow-xl shadow-black/10 backdrop-blur-sm",
      @class
    ]}>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:tone, :atom, default: :neutral, values: [:good, :bad, :warning, :neutral, :info])
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex w-fit items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-semibold capitalize",
      badge_classes(@tone),
      @class
    ]}>
      <span class={["size-1.5 rounded-full", badge_dot_classes(@tone)]}></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr(:type, :string, default: "button")
  attr(:tone, :atom, default: :primary, values: [:primary, :secondary, :danger, :ghost])
  attr(:class, :any, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "inline-flex min-h-10 items-center justify-center gap-2 rounded-xl px-4 py-2 text-sm font-bold transition focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-40 phx-submit-loading:cursor-wait phx-submit-loading:opacity-60",
        button_classes(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:href, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def link_button(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "inline-flex min-h-10 items-center justify-center gap-2 rounded-xl bg-emerald-400 px-4 py-2 text-sm font-bold text-emerald-950 transition hover:bg-emerald-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-400",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  attr(:label, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:type, :string, default: "text")
  attr(:hint, :string, default: nil)
  attr(:class, :any, default: nil)

  attr(:rest, :global,
    include:
      ~w(autocomplete disabled list max maxlength min minlength pattern placeholder readonly required step)
  )

  def input(assigns) do
    ~H"""
    <label class={["grid gap-2 text-sm font-medium text-zinc-300", @class]}>
      <span>{@label}</span>
      <input
        type={@type}
        name={@name}
        value={@value}
        class="min-h-11 w-full rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none transition placeholder:text-zinc-600 focus:border-emerald-400/70 focus:ring-3 focus:ring-emerald-400/10"
        {@rest}
      />
      <span :if={@hint} class="text-xs font-normal leading-5 text-zinc-500">{@hint}</span>
    </label>
    """
  end

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="grid gap-2" aria-live="polite">
      <div
        :if={message = Phoenix.Flash.get(@flash, :info)}
        class="rounded-xl border border-emerald-400/30 bg-emerald-400/10 px-4 py-3 text-sm text-emerald-100"
      >
        {message}
      </div>
      <div
        :if={message = Phoenix.Flash.get(@flash, :error)}
        class="rounded-xl border border-rose-400/30 bg-rose-400/10 px-4 py-3 text-sm text-rose-100"
        role="alert"
      >
        {message}
      </div>
    </div>
    """
  end

  attr(:name, :atom, required: true)
  attr(:class, :any, default: "size-5")

  def icon(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <%= case @name do %>
        <% :server -> %>
          <rect x="3" y="4" width="18" height="6" rx="2" />
          <rect x="3" y="14" width="18" height="6" rx="2" />
          <path d="M7 7h.01M7 17h.01" />
        <% :users -> %>
          <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
          <circle cx="9" cy="7" r="4" />
          <path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" />
        <% :alert -> %>
          <path d="M10.3 2.9 1.8 17a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 2.9a2 2 0 0 0-3.4 0Z" />
          <path d="M12 9v4M12 17h.01" />
        <% :network -> %>
          <circle cx="12" cy="5" r="2" />
          <circle cx="5" cy="19" r="2" />
          <circle cx="19" cy="19" r="2" />
          <path d="M12 7v5M5 17v-3h14v3" />
        <% :check -> %>
          <path d="m5 12 4 4L19 6" />
        <% :clock -> %>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 7v5l3 2" />
        <% :shield -> %>
          <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" />
        <% :menu -> %>
          <path d="M4 6h16M4 12h16M4 18h16" />
        <% :external -> %>
          <path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <% end %>
    </svg>
    """
  end

  defp badge_classes(:good), do: "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
  defp badge_classes(:bad), do: "border-rose-400/25 bg-rose-400/10 text-rose-300"
  defp badge_classes(:warning), do: "border-amber-400/25 bg-amber-400/10 text-amber-200"
  defp badge_classes(:info), do: "border-sky-400/25 bg-sky-400/10 text-sky-300"
  defp badge_classes(:neutral), do: "border-white/10 bg-white/5 text-zinc-300"

  defp badge_dot_classes(:good), do: "bg-emerald-400"
  defp badge_dot_classes(:bad), do: "bg-rose-400"
  defp badge_dot_classes(:warning), do: "bg-amber-300"
  defp badge_dot_classes(:info), do: "bg-sky-400"
  defp badge_dot_classes(:neutral), do: "bg-zinc-500"

  defp button_classes(:primary),
    do: "bg-emerald-400 text-emerald-950 hover:bg-emerald-300 focus-visible:outline-emerald-400"

  defp button_classes(:secondary),
    do:
      "border border-white/10 bg-white/5 text-zinc-100 hover:bg-white/10 focus-visible:outline-zinc-400"

  defp button_classes(:danger),
    do:
      "border border-rose-400/25 bg-rose-400/10 text-rose-200 hover:bg-rose-400/20 focus-visible:outline-rose-400"

  defp button_classes(:ghost),
    do: "text-zinc-300 hover:bg-white/5 hover:text-white focus-visible:outline-zinc-400"
end

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

defmodule NervesGateWeb.FormHelpers do
  @moduledoc false

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(:tailnet_online_timeout),
    do: "Tailnet did not become online in time; wait for Internet to stabilize and retry"

  def format_error(reason) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  def format_error(reason) when is_map(reason) do
    Enum.map_join(reason, ", ", fn {field, message} -> "#{field} #{message}" end)
  end

  def format_error(_reason), do: "operation failed"
end

defmodule NervesGateWeb.CoreComponents do
  @moduledoc "Reusable, presentation-only components shared by setup and dashboard views."

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
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
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
      ~w(autocomplete disabled list maxlength minlength pattern placeholder readonly required)
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

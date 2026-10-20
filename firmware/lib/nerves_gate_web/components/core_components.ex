defmodule NervesGateWeb.CoreComponents do
  @moduledoc "Reusable, stateless controls and surfaces for the local gateway UI."
  use Phoenix.Component

  @icons %{
    "overview" => "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
    "equipment" => "M3 4h18v12H3z M8 21h8 M12 16v5 M7 8h2 M7 12h6",
    "internet" =>
      "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18",
    "shield" => "m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z m-4 9 3 3 5-6",
    "settings" => "M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6",
    "port" => "M4 4h16v12h-4v4H8v-4H4z M8 4v5 M12 4v5 M16 4v5",
    "usb" =>
      "M12 3v14 M9 6l3-3 3 3 M12 13l-5-3V7 M12 16l5-3V9 M15 6h4v3h-4z M14 19a2 2 0 1 1-4 0 2 2 0 0 1 4 0",
    "arrow" => "M4 12h16 m-6-6 6 6-6 6",
    "check" => "m5 12 4 4L19 6",
    "info" => "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 11v6 M12 7v.01",
    "clock" => "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 7v5l3 2",
    "network" => "M9 3h6v6H9z M3 15h6v6H3z M15 15h6v6h-6z M12 9v3 M6 15v-3h12v3",
    "lock" => "M5 10h14v11H5z M8 10V7a4 4 0 0 1 8 0v3 M12 14v3"
  }

  attr(:name, :string, required: true)
  attr(:class, :string, default: nil)

  def icon(assigns) do
    assigns = assign(assigns, :path, Map.fetch!(@icons, assigns.name))

    ~H"""
    <svg
      class={["ui-icon", @class]}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.65"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d={@path} />
    </svg>
    """
  end

  attr(:eyebrow, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  slot(:actions)

  def page_header(assigns) do
    ~H"""
    <header class="ui-page-header">
      <div>
        <p :if={@eyebrow} class="ui-eyebrow">{@eyebrow}</p>
        <h1>{@title}</h1>
        <p :if={@description} class="ui-page-description">{@description}</p>
      </div>
      <div :if={@actions != []} class="ui-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:icon, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:meta)
  slot(:inner_block, required: true)
  slot(:footer)

  def panel(assigns) do
    ~H"""
    <section class={["ui-panel", @class]} {@rest}>
      <header class="ui-panel-header">
        <div class="ui-panel-heading">
          <span :if={@icon} class="ui-icon-box"><.icon name={@icon} /></span>
          <div>
            <h2>{@title}</h2><p :if={@description} class="ui-muted">{@description}</p>
          </div>
        </div>
        {render_slot(@meta)}
      </header>
      <div class="ui-panel-body">{render_slot(@inner_block)}</div>
      <footer :if={@footer != []} class="ui-panel-footer">{render_slot(@footer)}</footer>
    </section>
    """
  end

  attr(:href, :string, default: nil)
  attr(:type, :string, default: "button")
  attr(:variant, :string, values: ["primary", "secondary", "quiet"], default: "primary")
  attr(:icon, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:rest, :global, include: ~w(form name value target rel referrerpolicy))
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <a :if={@href} href={@href} class={["ui-button", "ui-button--#{@variant}"]} {@rest}>
      {render_slot(@inner_block)}<.icon :if={@icon} name={@icon} />
    </a>
    <button
      :if={!@href}
      type={@type}
      class={["ui-button", "ui-button--#{@variant}"]}
      disabled={@disabled or @loading}
      aria-busy={@loading && "true"}
      {@rest}
    >
      <span class="ui-spinner" aria-hidden="true"></span>
      {render_slot(@inner_block)}<.icon :if={@icon} name={@icon} />
    </button>
    """
  end

  attr(:tone, :string, values: ["neutral", "good", "warning"], default: "neutral")
  slot(:inner_block, required: true)

  def status(assigns) do
    ~H"""
    <span class={["ui-status", "ui-status--#{@tone}"]}><span aria-hidden="true"></span>{render_slot(
      @inner_block
    )}</span>
    """
  end

  attr(:title, :string, default: nil)
  attr(:tone, :string, values: ["neutral", "warning", "good"], default: "neutral")
  attr(:icon, :string, default: "info")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def notice(assigns) do
    ~H"""
    <div class={["ui-notice", "ui-notice--#{@tone}"]} {@rest}>
      <.icon name={@icon} /><div>
        <strong :if={@title}>{@title}</strong><div>{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  attr(:flash, :map, required: true)

  def notifications(assigns) do
    ~H"""
    <div id="notifications" class="ui-notifications" aria-label="Notifications">
      <div
        :for={kind <- [:info, :error]}
        :if={Phoenix.Flash.get(@flash, kind)}
        id={"notification-#{kind}"}
        class={["ui-toast", "ui-toast--#{kind}"]}
        role={if kind == :error, do: "alert", else: "status"}
        aria-atomic="true"
      >
        <p>{Phoenix.Flash.get(@flash, kind)}</p>
        <button
          type="button"
          class="ui-button ui-button--quiet"
          aria-label="Dismiss notification"
          phx-click="lv:clear-flash"
          phx-value-key={kind}
        >Dismiss</button>
      </div>
    </div>
    """
  end

  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, required: true)
  attr(:help, :string, default: nil)
  attr(:rest, :global, include: ~w(required placeholder autocomplete inputmode disabled))

  def field(assigns) do
    ~H"""
    <div class="ui-field">
      <label for={@field.id}>{@label}</label>
      <input
        type="text"
        id={@field.id}
        name={@field.name}
        value={@field.value}
        aria-describedby={@help && "#{@field.id}-help"}
        {@rest}
      />
      <p :if={@help} id={"#{@field.id}-help"} class="ui-help">{@help}</p>
    </div>
    """
  end

  @doc "A native, keyboard-accessible radio group. Choices stay visible; no popup or custom JS."
  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, required: true)
  attr(:description, :string, default: nil)

  slot :option, required: true do
    attr(:value, :string, required: true)
    attr(:title, :string, required: true)
    attr(:description, :string)
    attr(:icon, :string)
  end

  def choice_group(assigns) do
    ~H"""
    <fieldset class="ui-choice-group">
      <legend>{@label}</legend>
      <p :if={@description} class="ui-help">{@description}</p>
      <div class="ui-choices">
        <label :for={option <- @option} class="ui-choice">
          <input
            type="radio"
            id={"#{@field.id}-#{option.value}"}
            name={@field.name}
            value={option.value}
            checked={to_string(@field.value) == option.value}
          />
          <span class="ui-choice-content">
            <span class="ui-choice-title">{option.title}</span>
            <span :if={option[:description]} class="ui-choice-description">{option.description}</span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:href, :string, required: true)
  attr(:status, :string, default: nil)
  attr(:tone, :string, default: "neutral")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def navigation_card(assigns) do
    ~H"""
    <.link navigate={@href} class="ui-connection" {@rest}>
      <span class="ui-icon-box"><.icon name={@icon} /></span>
      <div class="ui-connection-copy">
        <h2>{@title}</h2><p>{render_slot(@inner_block)}</p>
      </div>
      <.status :if={@status} tone={@tone}>{@status}</.status>
      <.icon name="arrow" />
    </.link>
    """
  end

  attr(:label, :string, required: true)
  attr(:description, :string, default: nil)
  slot(:inner_block, required: true)

  def setting_row(assigns) do
    ~H"""
    <div class="ui-setting-row">
      <div>
        <h3>{@label}</h3><p :if={@description} class="ui-muted">{@description}</p>
      </div>
      <div class="ui-setting-value">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end

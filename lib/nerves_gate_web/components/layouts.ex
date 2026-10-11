defmodule NervesGateWeb.Layouts do
  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]
  import NervesGateWeb.CoreComponents, only: [icon: 1, notice: 1]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Nerves Gate</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script type="module" src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  # Keep navigation inside the LiveView layout so it follows live navigation,
  # including the return to Overview after first-time network setup.
  def app(assigns) do
    assigns = assign(assigns, :section, section(assigns.live_action))

    ~H"""
    <a href="#main-content" class="ui-skip-link">Skip to content</a>
    <header class="ui-header">
      <.link navigate="/" class="ui-brand"><.icon name="network" />Nerves Gate</.link>
      <nav aria-label="Main navigation" class="ui-navigation">
        <.link navigate="/" aria-current={if @section == :overview, do: "page"}>Overview</.link>
        <.link navigate="/equipment" aria-current={if @section == :equipment, do: "page"}>Equipment</.link>
        <.link navigate="/remote" aria-current={if @section == :remote, do: "page"}>Remote access</.link>
        <.link navigate="/settings" aria-current={if @section == :settings, do: "page"}>Settings</.link>
      </nav>
    </header>
    <main id="main-content" class="ui-main ui-stack" tabindex="-1">
      <div class="ui-disconnected">
        <.notice tone="warning" role="alert">
          Connection lost. Status may be out of date. Unconfirmed network changes restore automatically.
          Reconnect locally or through USB.
        </.notice>
      </div>
      <.notice
        :if={@projection.network.pending && @live_action != :network_settings}
        tone="warning"
        icon="clock"
        id="pending-network-notice"
      >
        Network changes are not saved yet. <.link navigate="/settings/network" class="ui-text-link">Keep or restore changes</.link>.
      </.notice>
      {@inner_content}
    </main>
    <footer class="ui-app-footer">
      Use a trusted network. This interface has no sign-in protection.
    </footer>
    """
  end

  attr(:current, :atom, required: true)

  def settings_nav(assigns) do
    ~H"""
    <nav aria-label="Settings" class="ui-subnav">
      <.link navigate="/settings" aria-current={if @current == :settings, do: "page"}>All settings</.link>
      <.link navigate="/settings/network" aria-current={if @current == :network, do: "page"}>Network</.link>
      <.link navigate="/settings/tailscale" aria-current={if @current == :tailscale, do: "page"}>Tailscale</.link>
      <.link navigate="/settings/buses" aria-current={if @current == :buses, do: "page"}>Buses</.link>
    </nav>
    """
  end

  defp section(:buses), do: :equipment
  defp section(action) when action in [:overview, :equipment, :remote], do: action
  defp section(_), do: :settings
end

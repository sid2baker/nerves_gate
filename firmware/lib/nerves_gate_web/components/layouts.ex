defmodule NervesGateWeb.Layouts do
  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]

  import NervesGateWeb.CoreComponents,
    only: [icon: 1, notice: 1, notifications: 1, theme_toggle: 1]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Nerves Gate</title>
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
        <script phx-track-static type="module" src="/assets/js/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def app(assigns) do
    assigns = assign(assigns, :section, section(assigns.live_action))

    ~H"""
    <a href="#main-content" class="ui-skip-link">Skip to content</a>
    <header class="ui-header">
      <.link navigate="/" class="ui-brand"><.icon name="network" />Nerves Gate</.link>
      <div class="ui-header-end">
        <nav aria-label="Main navigation" class="ui-navigation">
          <.link navigate="/" aria-current={if @section == :overview, do: "page"}>Overview</.link>
          <a href="/plugins" aria-current={if @section == :plugins, do: "page"}>Plugins</a>
          <.link navigate="/io" aria-current={if @section == :io, do: "page"}>I/O</.link>
          <.link navigate="/hardware" aria-current={if @section == :hardware, do: "page"}>Hardware</.link>
          <.link
            navigate="/settings"
            aria-current={if @section == :settings, do: "page"}
          >Settings</.link>
        </nav>
        <.theme_toggle />
      </div>
    </header>
    <main id="main-content" class="ui-main ui-stack" tabindex="-1">
      <div class="ui-disconnected">
        <.notice tone="warning" role="alert">
          Connection lost. Status may be out of date. Unconfirmed network changes restore automatically.
          Reconnect locally or through USB.
        </.notice>
      </div>
      <.notice
        :if={!@projection.device.available}
        tone="warning"
        role="alert"
        id="device-disconnected"
      >
        Device disconnected. Reconnecting… Commands are disabled and will not be retried.
        Unconfirmed network changes restore automatically on the device.
      </.notice>
      <.notice
        :if={@projection.network.pending && @live_action not in [:network, :lan]}
        tone="warning"
        icon="clock"
        id="pending-network-notice"
      >
        Network changes are not saved yet. <.link navigate="/network" class="ui-text-link">Keep or restore changes</.link>.
      </.notice>
      {@inner_content}
    </main>
    <.notifications flash={@flash} />
    """
  end

  defp section(action) when action in [:plugins, :plugin], do: :plugins
  defp section(action) when action in [:hardware, :lan, :rs485, :can], do: :hardware
  defp section(action) when action in [:settings, :storage], do: :settings
  defp section(:io), do: :io
  defp section(_), do: :overview
end

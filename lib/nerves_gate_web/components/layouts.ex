defmodule NervesGateWeb.Layouts do
  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]
  import NervesGateWeb.CoreComponents, only: [icon: 1]

  def root(assigns) do
    assigns = assign(assigns, :path, assigns.conn.request_path)

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
      <body>
        <a href="#main-content" class="ui-skip-link">Skip to content</a>
        <header class="ui-header">
          <a href="/" class="ui-brand"><.icon name="network" />Nerves Gate</a>
          <nav aria-label="Main navigation" class="ui-navigation">
            <a href="/" aria-current={if @path == "/", do: "page"}>Gateway</a>
            <a href="/settings" aria-current={if @path in ["/settings", "/setup"], do: "page"}>Network</a>
            <a href="/remote" aria-current={if @path == "/remote", do: "page"}>Tailscale</a>
          </nav>
        </header>
        <main id="main-content" class="ui-main" tabindex="-1">{@inner_content}</main>
        <footer class="ui-app-footer">
          Use a trusted network. This interface has no sign-in protection.
        </footer>
      </body>
    </html>
    """
  end
end

defmodule NervesGateWeb.Layouts do
  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]
  import NervesGateWeb.CoreComponents, only: [icon: 1]

  def root(assigns) do
    assigns =
      assign(assigns,
        path: assigns.conn.request_path,
        navigation: [
          {"/", "Overview", "overview"},
          {"/equipment", "Equipment", "equipment"},
          {"/internet", "Internet & backup", "internet"},
          {"/remote", "Remote access", "shield"},
          {"/settings", "Settings", "settings"}
        ]
      )

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
        <div class="ui-app-shell">
          <aside class="ui-sidebar" aria-label="Gateway navigation">
            <a href="/" class="ui-brand"><span><.icon name="network" /></span><div>
              Nerves Gate<small>Equipment gateway</small>
            </div></a>
            <nav aria-label="Main navigation" class="ui-navigation">
              <a
                :for={{path, label, icon} <- @navigation}
                href={path}
                aria-current={if @path == path, do: "page"}
              ><.icon name={icon} /><span>{label}</span></a>
            </nav>
            <div class="ui-sidebar-bottom">
              <div class="ui-local-label">
                <.icon name="usb" /><div>
                  <strong>Local management</strong><span>Setup & recovery</span>
                </div>
              </div>
            </div>
          </aside>
          <div class="ui-workspace">
            <header class="ui-topbar">
              <span>YOUR GATEWAY</span><span><.icon name="lock" />Local setup</span>
            </header>
            <main id="main-content" class="ui-main" tabindex="-1">{@inner_content}</main>
            <footer class="ui-app-footer">
              <span>Nerves Gate</span><span>Local setup is separate from remote access.</span>
            </footer>
          </div>
        </div>
      </body>
    </html>
    """
  end
end

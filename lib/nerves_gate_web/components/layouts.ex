defmodule NervesGateWeb.Layouts do
  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Nerves Gate</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script type="module" src="/assets/app.js">
        </script>
      </head>
      <body class="bg-base-200 min-h-screen text-base-content">
        <header class="navbar bg-base-100 border-b border-base-300 px-6">
          <a href="/" class="font-bold text-xl">Nerves Gate</a>
          <span class="ml-auto badge badge-outline">Local management</span>
        </header>
        <main class="max-w-4xl mx-auto p-6 space-y-6">{@inner_content}</main>
      </body>
    </html>
    """
  end
end

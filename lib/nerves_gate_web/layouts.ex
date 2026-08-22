defmodule NervesGateWeb.Layouts do
  @moduledoc false
  use NervesGateWeb, :html

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-zinc-950">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="theme-color" content="#09090b" />
        <title>NervesGate</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script type="module" src="/assets/app.js"></script>
      </head>
      <body class="min-h-full">
        {@inner_content}
      </body>
    </html>
    """
  end
end

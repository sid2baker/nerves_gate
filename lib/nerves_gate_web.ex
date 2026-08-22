defmodule NervesGateWeb do
  @moduledoc false

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      import Phoenix.Component
      import NervesGateWeb.CoreComponents
      alias NervesGateWeb.Layouts
      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import NervesGateWeb.CoreComponents
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(verified_routes())
    end
  end

  defp verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: NervesGateWeb.Endpoint,
        router: NervesGateWeb.Router,
        statics: []
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end

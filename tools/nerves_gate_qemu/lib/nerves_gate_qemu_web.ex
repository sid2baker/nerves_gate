defmodule NervesGateQEMUWeb do
  @moduledoc false

  def live_view do
    quote do
      use Phoenix.LiveView
      import Phoenix.Component
      import NervesGateQEMUWeb.CoreComponents
      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import NervesGateQEMUWeb.CoreComponents
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(verified_routes())
    end
  end

  defp verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: NervesGateQEMUWeb.Endpoint,
        router: NervesGateQEMUWeb.Router,
        statics: []
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end

defmodule NervesGateWeb.DistributionLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.{DistributionPanel, Observations}

  def mount(_, _, socket) do
    socket = Observations.subscribe(socket, &refresh/2)
    {:ok, refresh(socket, socket.assigns.projection)}
  end

  defp refresh(socket, projection) do
    cookie =
      cond do
        not projection.device.available ->
          nil

        not Map.has_key?(socket.assigns, :cookie) or
          not socket.assigns.projection.device.available or
            socket.assigns.projection.system.node != projection.system.node ->
          {:ok, cookie} = NervesGate.Distribution.cookie()
          cookie

        true ->
          socket.assigns.cookie
      end

    assign(socket, projection: projection, cookie: cookie)
  end

  def render(assigns) do
    ~H"""
    <.back_link navigate="/">Overview</.back_link>
    <.page_header
      title="Erlang distribution"
      description="Connect directly to this gateway’s runtime."
    />
    <DistributionPanel.connection
      node={@projection.system.node}
      cookie={@cookie}
      elixir={@projection.system.elixir}
      otp={@projection.system.otp}
    />
    """
  end
end

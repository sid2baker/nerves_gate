defmodule NervesGateWeb.DistributionLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.{DistributionPanel, Observations}

  def mount(_, _, socket) do
    {:ok, socket |> Observations.subscribe(&refresh/1) |> refresh()}
  end

  defp refresh(socket) do
    projection = NervesGateWeb.Backend.status()

    cookie =
      if projection.backend.available do
        case NervesGateWeb.Backend.distribution_cookie() do
          {:ok, cookie} -> cookie
          {:error, _} -> nil
        end
      end

    assign(socket, projection: projection, cookie: cookie)
  end

  def render(assigns) do
    ~H"""
    <.link navigate="/" class="ui-text-link">Back to Overview</.link>
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

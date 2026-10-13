defmodule NervesGateWeb.DistributionLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.DistributionPanel

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    assigns = assign(assigns, node: Node.self(), cookie: Node.get_cookie())

    ~H"""
    <.link navigate="/" class="ui-text-link">Back to Overview</.link>
    <.page_header
      title="Erlang distribution"
      description="Connect directly to this gateway’s runtime."
    />
    <DistributionPanel.connection
      node={@node}
      cookie={@cookie}
      elixir={System.version()}
      otp={System.otp_release()}
    />
    """
  end
end

defmodule NervesGateWeb.ConnectionPanel do
  @moduledoc "Connection details rendered from the parent's observed view, never its form draft."
  use Phoenix.LiveComponent
  import NervesGateWeb.NetworkStatus

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.topology projection={@projection} />
    </div>
    """
  end
end

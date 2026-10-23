defmodule NervesGateWeb.NetworkLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  on_mount({NervesGateWeb.Access, :network})

  def render(assigns) do
    ~H"""
    <.back_link navigate="/">Overview</.back_link>
    <.page_header
      title="Internet"
      description="Choose your Internet source. USB stays independent for recovery."
    />
    <.live_component
      module={NervesGateWeb.ConnectionPanel}
      id="network-connections"
      projection={@projection}
    />
    <.live_component
      module={NervesGateWeb.NetworkEditor}
      id="internet-editor"
      editor={:internet}
      projection={@projection}
      access={@access}
    />
    <.live_component
      module={NervesGateWeb.CellularPanel}
      id="cellular-panel"
      projection={@projection}
    />
    """
  end
end

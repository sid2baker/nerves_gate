defmodule NervesGateWeb.NetworkLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  on_mount({NervesGateWeb.Access, :network})

  def render(assigns) do
    ~H"""
    <.link navigate="/" class="ui-text-link">Back to Overview</.link>
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
    """
  end
end

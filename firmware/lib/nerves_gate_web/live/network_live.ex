defmodule NervesGateWeb.NetworkLive do
  use Phoenix.LiveView, log: false
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  on_mount({NervesGateWeb.Access, :network})

  def render(assigns) do
    ~H"""
    <.back_link navigate={if @live_action == :details, do: "/network", else: "/"}>{if @live_action ==
                                                                                        :details,
                                                                                      do: "Internet",
                                                                                      else: "Overview"}</.back_link>
    <.page_header
      title={if @live_action == :details, do: "Connection settings", else: "Internet"}
      description={
        if @live_action == :details,
          do: "Carrier, addressing and diagnostics.",
          else: "Choose a connection. SIM setup is automatic where supported."
      }
    />
    <.live_component
      module={NervesGateWeb.NetworkEditor}
      id={if @live_action == :details, do: "internet-settings-editor", else: "internet-editor"}
      editor={:internet}
      settings={@live_action == :details}
      projection={@projection}
      access={@access}
    />
    """
  end
end

defmodule NervesGateWeb.RemoteStatus do
  @moduledoc "Read-only Tailscale observations, shared by operations and settings."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:remote, :map, required: true)
  attr(:title, :string, default: "This gateway")
  slot(:inner_block)

  def connection(assigns) do
    ~H"""
    <.panel title={@title} icon="shield" id="gateway-remote-access">
      <:meta>
        <.status tone={if @remote.available && @remote.state == "online", do: "good", else: "neutral"}>
          {label(@remote)}
        </.status>
      </:meta>
      <p :if={!@remote.available}>
        Tailscale is starting or unavailable. Check that the daemon is installed and the gateway has Internet access.
      </p>
      <p :if={@remote.auth_state == "needs_approval"} role="status">
        Approve this gateway in your Tailscale admin console. This page updates automatically.
      </p>
      <p :if={@remote.operation} role="status">{operation(@remote.operation)}</p>
      <.notice :if={@remote.error} tone="warning" role="alert">{@remote.error.message}</.notice>
      <.notice :if={@remote.auth_state == "error" && @remote.error == nil} tone="warning" role="alert">
        Tailscale sign-in failed. Check your Internet connection and try connecting again.
      </.notice>
      <div :if={@remote.available && @remote.state == "online"} class="ui-settings-list">
        <.setting_row label="Tailscale address">
          <code>{@remote.ipv4 || "Waiting for an address"}</code>
        </.setting_row>
        <.setting_row :if={@remote.dns_name} label="DNS name">
          <code>{@remote.dns_name}</code>
        </.setting_row>
      </div>
      <p :for={warning <- @remote.health} class="ui-help">{warning}</p>
      {render_slot(@inner_block)}
    </.panel>
    """
  end

  def label(%{available: false}), do: "Unavailable"
  def label(%{state: "online"}), do: "Connected"
  def label(%{auth_state: "needs_approval"}), do: "Waiting for approval"
  def label(%{auth_state: "authenticating"}), do: "Waiting for sign-in"
  def label(_), do: "Not connected"

  defp operation("connect"), do: "Connecting to Tailscale…"
  defp operation("disconnect"), do: "Disconnecting…"

  defp operation(operation)
       when operation in ["sharing_enable", "sharing_disable", "sharing_sync"],
       do: "Checking equipment routes…"

  defp operation(_), do: "Saving device name…"
end

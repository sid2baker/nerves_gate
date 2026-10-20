defmodule NervesGateWeb.DistributionPanel do
  @moduledoc false
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:node, :atom, required: true)
  attr(:cookie, :atom, required: true)
  attr(:elixir, :string, required: true)
  attr(:otp, :string, required: true)

  def connection(assigns) do
    ~H"""
    <.panel title="Erlang distribution" icon="network" id="erlang-distribution">
      <%= if @node == :nonode@nohost do %>
        <p id="distribution-disabled" class="ui-help">
          Not running. Firmware starts distribution automatically when Tailscale is online
          and has an IPv4 address. Host preview does not start distribution.
        </p>
      <% else %>
        <.setting_row label="Node name">
          <code id="distribution-node">{@node}</code>
        </.setting_row>
        <.setting_row label="Cookie">
          <code id="distribution-cookie">{@cookie}</code>
        </.setting_row>
        <.notice tone="warning">
          Anyone with this cookie and network access can execute code on the gateway.
          This page uses the existing trusted-network access model; it has no sign-in protection.
        </.notice>
        <p class="ui-help">
          In Livebook on your computer, choose Attached node and copy the node name and cookie above.
          Connect your computer to the tailnet and allow TCP 4369 (EPMD) and 9100 (distribution)
          in your Tailscale policy.
        </p>
        <p class="ui-help">
          The cookie is shared by nodes that should connect, but matching cookies do not discover
          or automatically join nodes. Use Node.connect/1 explicitly. Distribution is not encrypted;
          use Tailscale or a trusted local network.
        </p>
        <p class="ui-help">
          Livebook must run the same Elixir minor version and a compatible OTP version.
          Add dependencies to firmware, not with Mix.install/2. Keep permanent equipment connections
          supervised by the gateway application.
        </p>
      <% end %>
      <.setting_row label="Runtime">Elixir {@elixir} · OTP {@otp}</.setting_row>
    </.panel>
    """
  end
end

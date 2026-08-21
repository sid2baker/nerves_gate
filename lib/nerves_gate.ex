defmodule NervesGate do
  @moduledoc "A small, Tailscale-backed Nerves gateway."

  @doc "Configure and verify the Internet uplink."
  defdelegate configure_internet(params), to: NervesGate.Setup

  @doc "Enroll Tailscale without persisting the auth token."
  defdelegate configure_tailscale(auth_token), to: NervesGate.Setup

  @doc "Start distribution and cluster discovery over Tailscale."
  defdelegate configure_cluster(), to: NervesGate.Setup

  @doc "Return a secret-free status snapshot."
  defdelegate status(), to: NervesGate.Status, as: :snapshot
end

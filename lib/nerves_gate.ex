defmodule NervesGate do
  @moduledoc "A small, Tailscale-backed Nerves gateway."

  @doc "Configure and verify the Internet uplink."
  defdelegate configure_internet(params), to: NervesGate.Setup

  @doc "Enroll Tailscale without persisting the auth token."
  defdelegate configure_tailscale(auth_token), to: NervesGate.Setup

  @doc "Select singular mode for compatibility with the current web setup flow."
  defdelegate configure_cluster(), to: NervesGate.Setup

  @doc "Configure the optional cluster cookie; nil selects singular mode."
  defdelegate configure_cluster(cookie), to: NervesGate.Setup, as: :configure_cluster_cookie

  @doc "Return a secret-free status snapshot."
  defdelegate status(), to: NervesGate.Status, as: :snapshot
end

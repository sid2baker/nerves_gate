defmodule NervesGate do
  @moduledoc "A small, Tailscale-backed Nerves gateway."

  @doc "Configure and verify the Internet uplink."
  defdelegate configure_internet(params), to: NervesGate.Setup

  @doc "Enroll Tailscale without persisting the auth token."
  defdelegate configure_tailscale(auth_token), to: NervesGate.Setup

  @doc "Select singular cluster mode."
  defdelegate configure_cluster(), to: NervesGate.Setup

  @doc "Configure the public cluster group; nil selects singular mode."
  defdelegate configure_cluster(group), to: NervesGate.Setup, as: :configure_cluster_group

  @doc "Return this gateway's authoritative, secret-free device data."
  defdelegate device_state(), to: NervesGate.DeviceState.Server, as: :data

  @doc "Return local replicas of currently or previously connected devices."
  defdelegate replicas(), to: NervesGate.DeviceState.Client

  @doc "Return the temporary web compatibility projection."
  defdelegate status(), to: NervesGate.Status, as: :snapshot
end

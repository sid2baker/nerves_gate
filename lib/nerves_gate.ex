defmodule NervesGate do
  @moduledoc "A small, Tailscale-backed Nerves gateway."

  @doc "Return the public firmware-tagged configuration status."
  defdelegate configuration(), to: NervesGate.DeviceState.Server

  @doc "Return this gateway's authoritative, secret-free device data."
  defdelegate device_state(), to: NervesGate.DeviceState.Server, as: :data

  @doc "Return local replicas of currently or previously connected devices."
  defdelegate replicas(), to: NervesGate.DeviceState.Client

  @doc "Return the temporary web compatibility projection."
  defdelegate status(), to: NervesGate.Status, as: :snapshot
end

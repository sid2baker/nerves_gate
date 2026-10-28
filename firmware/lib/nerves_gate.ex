defmodule NervesGate do
  @moduledoc """
  Gateway reads and caller-owned observation subscriptions.

  Commands belong to their domains: `NervesGate.Network`, `NervesGate.Cellular`,
  `NervesGate.Remote`, `NervesGate.Hardware`,
  `NervesGate.Indicators`, `NervesGate.SSH` and `NervesGate.Storage`.
  Observable inputs and runtime-only desired outputs belong to `NervesGate.IO`;
  its snapshots and subscriptions are separate from administrative status.
  `NervesGate.IO.Manual` is the gateway's manual writer.
  Read build/runtime identity with `NervesGate.System.info/0`.
  Equipment identities and discovery belong to plugins.

  Subscribe before reading, and subscribe afresh after reconnecting. Notifications
  are hints to reread, not atomic snapshots. Commands acknowledge acceptance, not
  necessarily completion; a timeout never cancels admitted work or permits blind
  replay. Private login URLs and distribution cookies are explicit domain reads,
  never part of this administrative status or the separate typed SDK contract.
  """
  alias NervesGate.{Hardware, Indicators, Network, Remote, SSH, Status, Storage}

  @doc "Read domain state directly and independently, without consulting the projection cache."
  @spec status() :: map()
  def status do
    Status.build(
      Network.status(),
      Remote.status(),
      Indicators.status(),
      Hardware.status(),
      SSH.status(),
      NervesGate.System.info(),
      Storage.commissioning()
    )
  end

  @doc "Subscribe the calling process to domain observations before reading status."
  @spec subscribe() :: :ok | {:error, NervesGate.Error.t()}
  def subscribe do
    with :ok <- Network.observe(),
         :ok <- Remote.observe(),
         :ok <- Indicators.observe(),
         :ok <- Hardware.observe(),
         :ok <- SSH.observe(),
         do: Storage.observe()
  end
end

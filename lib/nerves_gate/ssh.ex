defmodule NervesGate.SSH do
  @moduledoc """
  Controls the Tailnet-only NervesSSH IEx listener.

  Enabling SSH persists the desired setting through the authoritative device
  state. The listener itself remains stopped until a concrete Tailscale IPv4
  address is available.
  """

  use Supervisor

  alias NervesGate.DeviceState.Server
  alias NervesGate.SSH.Manager

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec enable() :: :ok | {:error, term()}
  def enable, do: Server.configure_ssh(true)

  @spec disable() :: :ok | {:error, term()}
  def disable, do: Server.configure_ssh(false)

  @spec status() :: Manager.status()
  def status, do: Manager.status()

  @impl true
  def init(_options) do
    children = [
      {DynamicSupervisor, name: NervesGate.SSH.DynamicSupervisor, strategy: :one_for_one},
      Manager
    ]

    # Escalate subsystem programming failures to Backend's rest-for-one tree so
    # DeviceState restarts, reloads ssh_enabled, and reapplies the desired state.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 0, max_seconds: 1)
  end
end

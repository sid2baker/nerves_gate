defmodule NervesGate do
  @moduledoc """
  Public state-reducer and command boundary.

  Clients subscribe once, own an immutable reducer value, and apply ordered
  operations in their existing process. Commands express intent to the owner of
  the affected resource; completed public reality returns through the shared
  state stream.
  """

  alias NervesGate.Client
  alias NervesGate.Firmware
  alias NervesGate.Gateway.Configuration

  @type resource_id :: String.t()
  @type settings_scope :: :internet | :tailnet | :cluster
  @type management_connection :: map()
  @type command_result :: :ok | {:error, term()}
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Subscribes the caller and returns its immutable state reducer."
  @spec connect() :: {:ok, Client.t(), Client.fleet()} | {:error, term()}
  def connect do
    with {:ok, client} <- Client.connect() do
      {:ok, client, Client.state(client)}
    end
  end

  @doc "Purely applies one state message to a client reducer."
  @spec reduce(Client.t(), term()) :: Client.reduction()
  defdelegate reduce(client, message), to: Client

  @doc "Atomically reinstalls local and fleet snapshots after a revision gap."
  @spec resync(Client.t()) :: {:ok, Client.t()} | {:error, term()}
  defdelegate resync(client), to: Client

  @doc "Returns the reducer's complete current local and fleet state."
  @spec state(Client.t()) :: Client.fleet()
  defdelegate state(client), to: Client

  @doc "Unsubscribes the calling process."
  @spec disconnect(Client.t()) :: :ok
  defdelegate disconnect(client), to: Client

  @doc "Returns whether first-time commissioning is complete."
  @spec configured?(Client.t()) :: boolean()
  defdelegate configured?(client), to: Client

  @doc "Returns the dashboard actor represented by a remote Tailnet address."
  @spec actor_for_ip(Client.t(), String.t()) :: map()
  defdelegate actor_for_ip(client, remote_ip), to: Client

  @doc "Returns Tailnet-only gateway discovery metadata."
  @spec discovery(Client.t()) :: map()
  defdelegate discovery(client), to: Client

  @doc "Returns the versioned, secret-free status document."
  @spec status(Client.t()) :: map()
  defdelegate status(client), to: Client

  @doc "Refreshes the signed firmware release catalog."
  @spec check_firmware() :: command_result()
  def check_firmware, do: Firmware.check()

  @doc "Downloads and verifies one discovered firmware release."
  @spec prepare_firmware(resource_id(), resource_id()) :: command_result()
  def prepare_firmware(release_id, connection_id),
    do: Firmware.prepare(release_id, connection_id)

  @doc "Installs a previously verified firmware release into the platform's trial slot."
  @spec install_firmware(resource_id(), resource_id()) :: command_result()
  def install_firmware(release_id, connection_id),
    do: Firmware.install(release_id, connection_id)

  @doc "Accepts a healthy trial firmware from a fresh Tailnet management connection."
  @spec accept_firmware(resource_id(), management_connection()) :: command_result()
  def accept_firmware(trial_id, connection), do: Firmware.accept(trial_id, connection)

  @doc "Immediately schedules the previous known-good firmware and reboots."
  @spec rollback_firmware(resource_id()) :: command_result()
  def rollback_firmware(trial_id), do: Firmware.rollback(trial_id)

  @doc "Applies one guarded connection-settings update pending an explicit Keep command."
  @spec update_settings(settings_scope(), map(), resource_id(), pos_integer()) :: result(map())
  def update_settings(scope, params, connection_id, timeout),
    do: Configuration.update_settings(scope, params, connection_id, timeout)

  @doc "Stages Internet settings during complete commissioning."
  @spec stage_internet(map(), resource_id(), pos_integer() | nil) :: result(map())
  def stage_internet(params, connection_id, timeout),
    do: Configuration.stage_internet(params, connection_id, timeout)

  @doc "Stages Tailnet settings in the active candidate."
  @spec stage_tailnet(resource_id(), map()) :: result(map())
  def stage_tailnet(id, params), do: Configuration.stage_tailnet(id, params)

  @doc "Stages Cluster settings in the active candidate."
  @spec stage_cluster(resource_id(), map()) :: result(map())
  def stage_cluster(id, params), do: Configuration.stage_cluster(id, params)

  @doc "Keeps a guarded candidate from a fresh Tailnet connection."
  @spec keep_settings(resource_id(), management_connection()) :: command_result()
  def keep_settings(id, connection), do: Configuration.confirm(id, connection)

  @doc "Rejects the active candidate and restores accepted settings."
  @spec revert(resource_id()) :: command_result()
  def revert(id), do: Configuration.revert(id)

  @doc "Changes accepted subnet-router settings."
  @spec configure_subnet_router(boolean(), [String.t()]) :: result(map())
  def configure_subnet_router(enabled, routes),
    do: Configuration.configure_subnet_router(enabled, routes)

  @doc "Changes accepted Tailnet-only Remote IEx settings."
  @spec configure_ssh(boolean()) :: command_result()
  def configure_ssh(enabled), do: Configuration.configure_ssh(enabled)
end

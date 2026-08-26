defmodule NervesGate do
  @moduledoc """
  Public client-session and command boundary.

  Clients connect once and receive complete live state from a disposable
  session. Commands express intent to the subsystem that owns the affected
  resource; resulting public reality returns through the session stream.
  """

  alias NervesGate.Gateway.Configuration
  alias NervesGate.Session
  alias NervesGate.Session.Supervisor, as: SessionSupervisor

  @doc "Starts a live state session owned by the calling client."
  @spec connect() :: {:ok, pid(), Session.fleet()} | {:error, term()}
  def connect do
    with {:ok, session} <- SessionSupervisor.start_session(self()) do
      {:ok, session, Session.state(session)}
    end
  end

  @doc "Returns the session's complete current local and fleet state."
  @spec state(GenServer.server()) :: Session.fleet()
  defdelegate state(session), to: Session

  @doc "Stops a disposable client session."
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc "Returns whether first-time commissioning is complete in this session."
  @spec configured?(GenServer.server()) :: boolean()
  defdelegate configured?(session), to: Session

  @doc "Returns the dashboard actor represented by a remote Tailnet address."
  @spec actor_for_ip(GenServer.server(), String.t()) :: map()
  defdelegate actor_for_ip(session, remote_ip), to: Session

  @doc "Returns Tailnet-only gateway discovery metadata from the session."
  @spec discovery(GenServer.server()) :: map()
  defdelegate discovery(session), to: Session

  @doc "Returns the versioned, secret-free status document for the session."
  @spec status(GenServer.server()) :: map()
  defdelegate status(session), to: Session

  @doc "Begins a Tailnet-only or Cluster-only guarded settings change."
  def begin_change(scope, connection_id, timeout),
    do: Configuration.begin_change(scope, connection_id, timeout)

  @doc "Stages Internet settings during complete commissioning."
  def stage_internet(params, connection_id, timeout),
    do: Configuration.stage_internet(params, connection_id, timeout)

  @doc "Updates Internet settings in a complete candidate."
  def update_internet(id, params), do: Configuration.update_internet(id, params)

  @doc "Stages Tailnet settings in the active candidate."
  def stage_tailnet(id, params), do: Configuration.stage_tailnet(id, params)

  @doc "Stages Cluster settings in the active candidate."
  def stage_cluster(id, params), do: Configuration.stage_cluster(id, params)

  @doc "Accepts a complete candidate from a fresh Tailnet connection."
  def confirm(id, connection), do: Configuration.confirm(id, connection)

  @doc "Rejects the active candidate and restores accepted settings."
  def revert(id), do: Configuration.revert(id)

  @doc "Changes accepted subnet-router settings."
  def configure_subnet_router(enabled, routes),
    do: Configuration.configure_subnet_router(enabled, routes)

  @doc "Changes accepted Tailnet-only Remote IEx settings."
  def configure_ssh(enabled), do: Configuration.configure_ssh(enabled)
end

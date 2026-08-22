defmodule NervesGate.Settings do
  @moduledoc "Thin public facade over subsystem-owned guarded settings changes."

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Setup
  alias NervesGate.Tailnet.Configuration, as: TailnetConfiguration

  @spec stage_internet(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def stage_internet(params, connection_id) do
    with :ok <- commissioned(),
         {:ok, config} <- Setup.internet_config(params) do
      InternetManager.stage_candidate(config, connection_id)
    end
  end

  @spec stage_tailnet(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stage_tailnet(auth_token, connection_id) do
    with :ok <- commissioned() do
      TailnetConfiguration.stage(auth_token, connection_id)
    end
  end

  @spec stage_cluster(String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def stage_cluster(group, connection_id) do
    with :ok <- commissioned() do
      ClusterManager.stage(group, connection_id)
    end
  end

  @spec confirm(String.t(), String.t()) :: :ok | {:error, term()}
  def confirm(change_id, connection_id) do
    case ChangeControl.active() do
      %{id: ^change_id, kind: :internet} -> InternetManager.confirm(change_id, connection_id)
      %{id: ^change_id, kind: :tailnet} -> TailnetConfiguration.confirm(change_id, connection_id)
      %{id: ^change_id, kind: :cluster} -> ClusterManager.confirm(change_id, connection_id)
      _other -> {:error, :settings_change_not_found}
    end
  end

  @spec revert(String.t()) :: :ok | {:error, term()}
  def revert(change_id) do
    case ChangeControl.active() do
      %{id: ^change_id, kind: :internet} -> InternetManager.revert(change_id)
      %{id: ^change_id, kind: :tailnet} -> TailnetConfiguration.revert(change_id)
      %{id: ^change_id, kind: :cluster} -> ClusterManager.revert(change_id)
      _other -> {:error, :settings_change_not_found}
    end
  end

  @spec status(String.t() | nil) :: map()
  def status(connection_id \\ nil), do: ChangeControl.status(connection_id)

  defp commissioned do
    if Setup.status().ready, do: :ok, else: {:error, :commissioning_required}
  end
end

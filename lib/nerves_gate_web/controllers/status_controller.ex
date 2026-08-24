defmodule NervesGateWeb.StatusController do
  @moduledoc false
  use NervesGateWeb, :controller

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Data
  alias NervesGate.DeviceState.Server
  alias NervesGate.Tailnet.Observer

  def show(connection, _params) do
    observation = Server.observation()

    json(connection, %{
      schema: "nerves_gate.status.v1",
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      configuration: public_configuration(observation.configuration),
      local: %{
        boot_id: observation.boot_id,
        revision: observation.revision,
        data: public_data(observation.data)
      },
      replicas: public_replicas(Client.replicas()),
      runtime: runtime()
    })
  end

  defp public_configuration(configuration) do
    %{
      configured: configuration.configured,
      current: configuration.current,
      change: public_change(configuration.pending)
    }
  end

  defp public_change(nil), do: nil
  defp public_change(change), do: Map.take(change, [:phase, :remaining_seconds])

  defp public_replicas(replicas) do
    Map.new(replicas, fn {id, replica} ->
      {id,
       %{
         boot_id: replica.boot_id,
         revision: replica.revision,
         connected: replica.connected,
         last_seen_at: encode_datetime(replica.last_seen_at),
         data: public_data(replica.data)
       }}
    end)
  end

  defp public_data(%Data{} = data) do
    data
    |> Data.to_map()
    |> update_in([:ssh, :address], &encode_address/1)
  end

  defp runtime do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)
    tailnet = Observer.status()
    cluster = ClusterManager.status()

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total),
      tailscale: public_tailscale_health(tailnet.health),
      cluster: %{candidates: cluster.candidates}
    }
  end

  defp public_tailscale_health(health) do
    health
    |> Map.from_struct()
    |> Map.take([
      :client,
      :daemon,
      :socket,
      :authenticated,
      :online,
      :restart_attempt,
      :transitioned_at
    ])
    |> Map.update!(:transitioned_at, &encode_datetime/1)
  end

  defp encode_address(nil), do: nil
  defp encode_address(address), do: address |> :inet.ntoa() |> List.to_string()

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end

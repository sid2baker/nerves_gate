defmodule NervesGate.Status do
  @moduledoc "Builds the secret-free dashboard snapshot."

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Device
  alias NervesGate.Distribution.Manager, as: DistributionManager
  alias NervesGate.Identity
  alias NervesGate.Network.Hardware
  alias NervesGate.Network.Manager, as: NetworkManager
  alias NervesGate.Network.Monitor
  alias NervesGate.Setup
  alias NervesGate.Tailscale.Observer

  @spec snapshot() :: map()
  def snapshot do
    tailnet = safe(Observer, :status, offline_tailnet())

    %{
      device: safe(Device, :get, %{"name" => Identity.get().hostname, "history" => []}),
      identity: Identity.get(),
      setup: safe(Setup, :status, %{phase: :internet, ready: false, recovery: false}),
      network: %{
        configuration: safe(NetworkManager, :status, %{}),
        connectivity: safe(Monitor, :status, %{}),
        interfaces: Hardware.interfaces()
      },
      tailnet: tailnet,
      people_count: safe(NervesGateWeb.Presence, :count, 0),
      distribution:
        safe(DistributionManager, :status, %{online: false, node: nil, connected: []}),
      cluster:
        safe(ClusterManager, :status, %{
          running: false,
          candidates: [],
          connected: [],
          missing: []
        })
        |> Map.put(:nodes, tailnet.nodes),
      alarms: Alarms.active(),
      diagnostics: diagnostics()
    }
  end

  @spec api_snapshot() :: map()
  def api_snapshot, do: snapshot() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp json_safe(value), do: value

  defp diagnostics do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      firmware_version: Application.spec(:nerves_gate, :vsn) |> to_string(),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp safe(module, function, fallback) do
    apply(module, function, [])
  catch
    :exit, _reason -> fallback
    _kind, _reason -> fallback
  end

  defp offline_tailnet do
    %{
      online: false,
      authenticated: false,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      candidates: [],
      error: :offline
    }
  end
end

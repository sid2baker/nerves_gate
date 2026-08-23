defmodule NervesGateQEMU.Status do
  @moduledoc "Combines host/QMP state with each gateway's local diagnostics API."

  alias NervesGateQEMU.Fault
  alias NervesGateQEMU.Runner

  @timeout 2_000

  @type state :: :online | :offline | :unknown

  @spec all() :: %{devices: [map()], observed_at: DateTime.t()}
  def all do
    topology = Runner.devices()

    devices =
      topology
      |> Task.async_stream(&device_status/1,
        ordered: true,
        max_concurrency: 8,
        timeout: @timeout + 1_000,
        on_timeout: :kill_task
      )
      |> then(&Enum.zip(topology, &1))
      |> Enum.map(fn
        {_device, {:ok, status}} -> status
        {device, {:exit, _reason}} -> unavailable_device(device)
      end)

    %{devices: devices, observed_at: DateTime.utc_now()}
  end

  @spec device_status(Runner.device()) :: map()
  def device_status(device) do
    vm = Fault.vm_state(device)
    link = if vm == :running, do: Fault.link_state(device), else: :unknown
    fault = if vm == :running, do: Fault.status(device), else: :unknown

    gateway =
      if vm == :running,
        do: fetch_gateway(device.status_url),
        else: {:error, :vm_unavailable}

    gateway_status(device, vm, link, fault, gateway)
  end

  defp gateway_status(device, vm, link, fault, {:ok, status}) do
    internet = status |> get_in(["network", "connectivity", "online"]) |> online_state()
    tailnet = status |> get_in(["tailnet", "online"]) |> online_state()
    cluster = status |> get_in(["cluster", "online"]) |> online_state()
    replicas = status |> get_in(["device_state", "replicas"]) |> map_or_empty()
    connected = Enum.count(replicas, fn {_id, replica} -> replica["connected"] == true end)

    base_device(device, vm, link, fault)
    |> Map.merge(%{
      configured: get_in(status, ["configuration", "configured"]) == true,
      internet: internet,
      tailnet: tailnet,
      cluster: cluster,
      tailnet_ip: get_in(status, ["tailnet", "ipv4"]),
      daemon: get_in(status, ["tailnet", "health", "daemon"]),
      replicas: map_size(replicas),
      connected_replicas: connected,
      stale_replicas: map_size(replicas) - connected,
      alarms: Map.get(status, "alarms", []),
      error: nil
    })
  end

  defp gateway_status(device, vm, link, fault, {:error, reason}) do
    base_device(device, vm, link, fault)
    |> Map.merge(%{
      configured: false,
      internet: :unknown,
      tailnet: :unknown,
      cluster: :unknown,
      tailnet_ip: nil,
      daemon: nil,
      replicas: 0,
      connected_replicas: 0,
      stale_replicas: 0,
      alarms: [],
      error: reason
    })
  end

  defp base_device(device, vm, link, fault) do
    %{
      id: device.id,
      slug: device.slug,
      port: device.port,
      iframe_url: device.iframe_url,
      status_url: device.status_url,
      vm: vm,
      link: link,
      fault: fault
    }
  end

  defp fetch_gateway(url) do
    request = {String.to_charlist(url), []}
    options = [timeout: @timeout, connect_timeout: @timeout]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> Jason.decode(body)
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp online_state(true), do: :online
  defp online_state(false), do: :offline
  defp online_state(_value), do: :unknown

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp unavailable_device(device) do
    %{
      id: device.id,
      slug: device.slug,
      port: device.port,
      iframe_url: device.iframe_url,
      status_url: device.status_url,
      vm: :unknown,
      link: :unknown,
      fault: :unknown,
      configured: false,
      internet: :unknown,
      tailnet: :unknown,
      cluster: :unknown,
      tailnet_ip: nil,
      daemon: nil,
      replicas: 0,
      connected_replicas: 0,
      stale_replicas: 0,
      alarms: [],
      error: :observation_failed
    }
  end
end

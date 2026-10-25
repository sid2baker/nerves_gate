defmodule Workbench.LANDiscovery do
  @moduledoc "Bounded, read-only LAN and tailnet discovery. Candidates are not authentication."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def refresh, do: GenServer.call(__MODULE__, :refresh)
  def add(address), do: GenServer.call(__MODULE__, {:add, address})
  def record_usb(info), do: GenServer.call(__MODULE__, {:usb, info})

  def record_read(address, status, message \\ nil),
    do: GenServer.call(__MODULE__, {:read, address, status, message})

  def record_identity(address, identity),
    do: GenServer.call(__MODULE__, {:identity, address, identity})

  def init(_),
    do:
      {:ok,
       %{
         task: nil,
         manual: %{},
         identities: %{},
         reads: %{},
         view: %{status: :idle, devices: [], error: nil}
       }}

  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(:refresh, _, %{task: task} = state) when not is_nil(task),
    do: {:reply, :ok, state}

  def handle_call(:refresh, _, state) do
    task =
      Task.Supervisor.async_nolink(Workbench.Tasks, fn ->
        {tailnet, warning} = discover_tailnet()
        lan = NervesDiscovery.discover(timeout: 3_000, method: :generic) |> devices()
        {lan ++ tailnet, warning}
      end)

    {:reply, :ok, %{state | task: task, view: %{state.view | status: :searching, error: nil}}}
  end

  def handle_call({:add, address}, _, state) do
    case manual(address) do
      {:ok, device} ->
        manual = Map.put(state.manual, device.address, device)

        devices =
          merge(state.view.devices, manual)
          |> enrich(Map.get(state, :identities, %{}))
          |> Enum.map(&put_read(&1, Map.get(state, :reads, %{})))

        GenServer.cast(Workbench.Operations, :read_discovered)
        {:reply, :ok, %{state | manual: manual, view: %{state.view | devices: devices}}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:usb, info}, _, state) do
    {:ok, device} = manual(info.address)
    public = Map.take(info, [:version, :target, :runtime, :read_at, :interface])

    device =
      Map.merge(device, %{
        name: "EC100 · USB",
        source: :usb,
        version: public.version,
        target: public.target,
        usb_info: public
      })

    manual = Map.put(state.manual, device.address, device)
    # A fresh factory boot invalidates an older SSH observation at this address.
    identities = Map.delete(state.identities, device.address)
    reads = Map.delete(Map.get(state, :reads, %{}), device.address)

    devices =
      merge(state.view.devices, manual) |> enrich(identities) |> Enum.map(&put_read(&1, reads))

    {:reply, :ok,
     Map.merge(state, %{
       manual: manual,
       identities: identities,
       reads: reads,
       view: %{state.view | devices: devices}
     })}
  end

  def handle_call({:read, address, status, message}, _, state)
      when status in [:reading, :succeeded, :failed] do
    reads = Map.put(Map.get(state, :reads, %{}), address, %{status: status, message: message})
    devices = Enum.map(state.view.devices, &put_read(&1, reads))

    {:reply, :ok,
     state |> Map.put(:reads, reads) |> Map.put(:view, %{state.view | devices: devices})}
  end

  def handle_call({:identity, address, identity}, _, state) do
    if Enum.any?(state.view.devices, &(&1.address == address)) do
      public =
        for key <- ["target", "version", "platform", "architecture", "product", "serial"],
            value = text(identity[key]),
            into: %{},
            do: {key, value}

      observed = %{values: public, read_at: DateTime.utc_now() |> DateTime.to_iso8601()}
      identities = Map.put(Map.get(state, :identities, %{}), address, observed)
      reads = Map.put(Map.get(state, :reads, %{}), address, %{status: :succeeded, message: nil})
      devices = enrich(state.view.devices, identities) |> Enum.map(&put_read(&1, reads))
      view = %{state.view | devices: devices}
      {:reply, :ok, Map.merge(state, %{identities: identities, reads: reads, view: view})}
    else
      {:reply, {:error, "Add the device address first"}, state}
    end
  end

  def handle_info({ref, {devices, warning}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    view = %{
      status: :ready,
      devices:
        merge(devices, state.manual)
        |> enrich(Map.get(state, :identities, %{}))
        |> Enum.map(&put_read(&1, Map.get(state, :reads, %{}))),
      error: warning
    }

    GenServer.cast(Workbench.Operations, :read_discovered)
    {:noreply, %{state | task: nil, view: view}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    {:noreply,
     %{
       state
       | task: nil,
         view: %{
           state.view
           | status: :failed,
             error: "LAN discovery failed. Check multicast access or add an address manually."
         }
     }}
  end

  # Only project known public fields; do not relay arbitrary network TXT data.
  def devices(results) do
    for result <- results,
        result[:product] == "Nerves Gate",
        address <- result[:addresses] || [],
        valid_address?(address) do
      %{
        name: text(result[:name]),
        address: to_string(:inet.ntoa(address)),
        version: text(result[:version]),
        target: text(result[:platform]),
        source: :mdns,
        url: gateway_url(address)
      }
    end
    |> Enum.uniq_by(& &1.address)
    |> Enum.sort_by(& &1.address)
  end

  def manual(address) do
    with {:ok, host, url} <- endpoint(address) do
      {:ok,
       %{
         name: "Manual address",
         address: host,
         version: nil,
         target: nil,
         source: :manual,
         explicit_url: String.contains?(address, "://"),
         url: url
       }}
    end
  end

  # Root URLs only: never retain credentials, login paths or query tokens.
  defp endpoint(address) when is_binary(address) do
    address = String.trim(address)

    if String.contains?(address, "://") do
      with {:ok, uri} <- URI.new(address),
           true <- uri.scheme in ["http", "https"],
           true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
           true <- uri.path in [nil, "", "/"],
           true <- is_integer(uri.port) and uri.port in 1..65535,
           {:ok, host} <- host(uri.host) do
        {:ok, host, URI.to_string(%{uri | host: host, path: "/"})}
      else
        _ -> {:error, "Supply a hostname, IPv4 address or root HTTP(S) URL without credentials"}
      end
    else
      with {:ok, host} <- host(address), do: {:ok, host, "http://#{host}:4000/"}
    end
  end

  defp endpoint(_), do: invalid_host()

  defp discover_tailnet do
    case Req.get("http://local-tailscaled.sock/localapi/v0/status",
           unix_socket: "/var/run/tailscale/tailscaled.sock",
           headers: [{"host", "local-tailscaled.sock"}],
           retry: false,
           connect_options: [timeout: 1_000],
           receive_timeout: 2_000
         ) do
      {:ok, %{status: 200, body: %{"BackendState" => "Running"} = status}} ->
        {tailnet_devices(status), nil}

      _ ->
        {[],
         "Tailnet discovery unavailable. Add a gateway URL manually; LAN discovery remains available."}
    end
  end

  # Names are hints only. Do not expose the peer catalogue or private daemon state.
  def tailnet_devices(%{"Peer" => peers}) when is_map(peers) do
    for peer <- Map.values(peers),
        peer["Online"] == true,
        {:ok, host} <- [host(peer["DNSName"])],
        label = hd(String.split(host, ".")),
        Regex.match?(~r/\Anerves-gate(?:-[a-z0-9-]+)?\z/, label) do
      %{
        name: label,
        address: host,
        version: nil,
        target: nil,
        source: :tailnet,
        url: "https://#{host}/"
      }
    end
    |> Enum.uniq_by(& &1.address)
    |> Enum.sort_by(& &1.address)
  end

  def tailnet_devices(_), do: []

  def host(address) when is_binary(address) do
    address = address |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    case :inet.parse_ipv4_address(to_charlist(address)) do
      {:ok, ip} ->
        if valid_address?(ip), do: {:ok, to_string(:inet.ntoa(ip))}, else: invalid_host()

      _ ->
        labels = String.split(address, ".")

        valid =
          byte_size(address) in 1..253 and
            not Regex.match?(~r/\A[0-9.]+\z/, address) and
            Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1))

        if valid, do: {:ok, address}, else: invalid_host()
    end
  end

  def host(_), do: invalid_host()
  defp invalid_host, do: {:error, "Supply a hostname or unicast IPv4 address, not a URL"}

  defp valid_address?({a, b, c, d}) when a > 0 and a < 224 and a != 127,
    do: Enum.all?([a, b, c, d], &(&1 in 0..255))

  defp valid_address?(_), do: false

  defp text(value) when is_binary(value),
    do: if(String.valid?(value), do: String.slice(value, 0, 120))

  defp text(_), do: nil
  defp gateway_url(ip), do: "http://#{:inet.ntoa(ip)}:4000/"

  defp put_read(device, reads) do
    case reads[device.address] do
      nil -> device
      read -> Map.put(device, :info_read, read)
    end
  end

  defp enrich(devices, identities) do
    Enum.map(devices, fn device ->
      case identities[device.address] do
        nil ->
          device

        identity ->
          device
          |> Map.put(:identity, identity)
          |> Map.put(:target, identity.values["target"])
          |> Map.put(:version, identity.values["version"])
      end
    end)
  end

  defp merge(devices, manual) do
    devices =
      Enum.map(devices, fn device ->
        case manual[device.address] do
          %{source: :usb} = usb -> usb
          %{source: :manual, explicit_url: true, url: url} -> Map.put(device, :url, url)
          _ -> device
        end
      end)

    (devices ++ Map.values(manual)) |> Enum.uniq_by(& &1.address) |> Enum.sort_by(& &1.address)
  end
end

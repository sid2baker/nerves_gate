defmodule Dev.Discovery do
  @moduledoc "Bounded, read-only local mDNS discovery. Advertisements are not authentication."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def refresh, do: GenServer.call(__MODULE__, :refresh)
  def add(address), do: GenServer.call(__MODULE__, {:add, address})

  def init(_),
    do: {:ok, %{task: nil, manual: %{}, view: %{status: :idle, devices: [], error: nil}}}

  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(:refresh, _, %{task: task} = state) when not is_nil(task),
    do: {:reply, :ok, state}

  def handle_call(:refresh, _, state) do
    task =
      Task.Supervisor.async_nolink(Dev.Tasks, fn ->
        NervesDiscovery.discover(timeout: 3_000, method: :generic) |> devices()
      end)

    {:reply, :ok, %{state | task: task, view: %{state.view | status: :searching, error: nil}}}
  end

  def handle_call({:add, address}, _, state) do
    case manual(address) do
      {:ok, device} ->
        manual = Map.put(state.manual, device.address, device)
        devices = merge(state.view.devices, manual)
        {:reply, :ok, %{state | manual: manual, view: %{state.view | devices: devices}}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_info({ref, devices}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    view = %{status: :ready, devices: merge(devices, state.manual), error: nil}
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
    with {:ok, host} <- host(address) do
      {:ok,
       %{
         name: "Manual address",
         address: host,
         version: nil,
         target: nil,
         source: :manual,
         url: "http://#{host}:4000/"
       }}
    end
  end

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

  defp merge(devices, manual),
    do:
      (devices ++ Map.values(manual)) |> Enum.uniq_by(& &1.address) |> Enum.sort_by(& &1.address)
end

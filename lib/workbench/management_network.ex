defmodule Workbench.ManagementNetwork do
  @moduledoc "Explicitly prepared, checkout-owned bridge/TAP hardware. Never changes networking on application startup."
  @journal "_build/workbench/network.term"

  def load do
    case File.read(@journal) do
      {:ok, bytes} -> :erlang.binary_to_term(bytes)
      {:error, :enoent} -> nil
      error -> raise "Cannot read prepared management network: #{inspect(error)}"
    end
  end

  @doc "Read recorded resources and current kernel identities without repairing networking."
  def status do
    case load() do
      nil ->
        %{status: :not_prepared}

      network ->
        resources =
          Enum.map(network.created, fn resource ->
            observed =
              case File.read("/sys/class/net/#{resource.name}/ifindex") do
                {:ok, index} -> String.trim(index)
                _ -> nil
              end

            %{name: resource.name, matches: observed == resource.index}
          end)

        %{
          status:
            if(network.ready and Enum.all?(resources, & &1.matches),
              do: :ready,
              else: :unavailable
            ),
          resources: resources
        }
    end
  rescue
    _ ->
      %{
        status: :unreadable,
        next: "Inspect the recorded management network; do not delete its journal or auto-repair."
      }
  end

  def setup!(subnet, ids) do
    if active_session?(),
      do: raise("Stop this checkout's Workbench sessions before preparing its network")

    if load(), do: raise("A network is already recorded; clean it up explicitly first")
    {output, 0} = System.cmd("ip", ["-json", "route", "show", "table", "all"])
    network = plan!(subnet, ids, JSON.decode!(output))

    {uid, 0} = System.cmd("id", ["-u"])
    network = Map.put(network, :uid, String.trim(uid))
    File.mkdir_p!(Path.dirname(@journal))
    # Journal only successfully created resources, including partial setup.
    :ok =
      File.write(@journal, :erlang.term_to_binary(Map.put(network, :created, [])), [:exclusive])

    File.chmod!(@journal, 0o600)
    create!(network.bridge, ["link", "add", network.bridge, "type", "bridge"])
    # Only the newly created bridge: never toggle workstation-wide forwarding.
    run!("sysctl", ["-w", "net.ipv4.conf.#{network.bridge}.forwarding=0"])
    ip!(["address", "add", network.host <> "/24", "dev", network.bridge])
    ip!(["link", "set", network.bridge, "up"])

    for {_id, port} <- network.devices do
      create!(port.tap, ["tuntap", "add", "dev", port.tap, "mode", "tap", "user", network.uid])
      ip!(["link", "set", port.tap, "master", network.bridge])
      ip!(["link", "set", port.tap, "up"])
    end

    persist!(%{load() | ready: true})
    load()
  end

  def cleanup! do
    if active_session?(),
      do: raise("Stop this checkout's Workbench sessions before network cleanup")

    if network = load() do
      case File.ls("/sys/class/net/#{network.bridge}/brif") do
        {:ok, members} ->
          unless members -- Enum.map(network.created, & &1.name) == [],
            do: raise("Unowned interfaces joined the management bridge; refusing cleanup")

        {:error, :enoent} ->
          :ok
      end

      for resource <- Enum.reverse(network.created) do
        case File.read("/sys/class/net/#{resource.name}/ifindex") do
          {:ok, index} ->
            unless String.trim(index) == resource.index,
              do: raise("Interface identity changed; refusing cleanup")

            ip!(["link", "delete", resource.name])

          {:error, :enoent} ->
            :ok
        end
      end

      File.rm!(@journal)
    end

    :ok
  end

  def verify!(network, id) do
    port = network && network.devices[id]

    unless network && network.ready && port && File.exists?("/sys/class/net/#{port.tap}/ifindex"),
      do: raise("Prepare QEMU networking first: mix dev.network setup --subnet <private-/24>")

    Enum.each(network.created, fn resource ->
      unless File.read!("/sys/class/net/#{resource.name}/ifindex") |> String.trim() ==
               resource.index,
             do: raise("Prepared network interface identity changed")
    end)

    unless String.trim(File.read!("/proc/sys/net/ipv4/conf/#{network.bridge}/forwarding")) == "0",
      do: raise("Management bridge forwarding changed; refusing QEMU startup")

    port
  end

  @doc false
  def plan!(subnet, ids, routes) do
    [address, "24"] = String.split(subnet, "/")
    {:ok, {a, b, c, 0}} = :inet.parse_ipv4_address(to_charlist(address))

    unless a == 10 or (a == 172 and b in 16..31) or (a == 192 and b == 168),
      do: raise("Choose a private IPv4 /24 network")

    for route <- routes, dst = route["dst"], is_binary(dst), dst != "default" do
      [ip | prefix] = String.split(dst, "/")

      case :inet.parse_ipv4_address(to_charlist(ip)) do
        {:ok, tuple} ->
          bits = if prefix == [], do: 32, else: String.to_integer(hd(prefix))
          shift = 32 - min(bits, 24)

          if Bitwise.bsr(integer(tuple), shift) == Bitwise.bsr(integer({a, b, c, 0}), shift),
            do: raise("Management subnet overlaps host route #{dst}")

        _ ->
          :ok
      end
    end

    unless length(ids) in 1..253, do: raise("Configure 1–253 devices before network setup")
    token = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    devices =
      ids
      |> Enum.sort()
      |> Enum.with_index(2)
      |> Map.new(fn {id, index} ->
        {id,
         %{
           address: "#{a}.#{b}.#{c}.#{index}",
           tap: "ngt#{token}#{index}",
           mac: Enum.join(["52", "54", hex(a), hex(b), hex(c), hex(index)], ":")
         }}
      end)

    %{
      bridge: "ngb#{token}",
      host: "#{a}.#{b}.#{c}.1",
      subnet: subnet,
      devices: devices,
      ready: false
    }
  end

  defp active_session? do
    Path.wildcard("_build/workbench*/session.lock")
    |> Enum.any?(&Workbench.Session.locked?(Path.dirname(&1)))
  end

  defp integer({a, b, c, d}), do: a * 16_777_216 + b * 65_536 + c * 256 + d
  defp hex(n), do: n |> Integer.to_string(16) |> String.pad_leading(2, "0")

  defp ip!(args), do: run!("ip", args)

  defp run!(tool, args) do
    case System.cmd("sudo", ["-n", tool | args], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        raise "Network operation failed: #{output}. Inspect the recorded resources; cleanup is explicit."
    end
  end

  defp create!(name, args) do
    ip!(args)
    index = File.read!("/sys/class/net/#{name}/ifindex") |> String.trim()
    network = load()
    persist!(%{network | created: network.created ++ [%{name: name, index: index}]})
  end

  defp persist!(network) do
    File.write!(@journal <> ".tmp", :erlang.term_to_binary(network))
    File.chmod!(@journal <> ".tmp", 0o600)
    File.rename!(@journal <> ".tmp", @journal)
  end
end

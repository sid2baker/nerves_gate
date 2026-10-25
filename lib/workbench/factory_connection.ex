defmodule Workbench.FactoryConnection do
  @moduledoc "Read-only, bounded USB reconnection after verified factory provisioning."
  import Bitwise
  alias NervesGate.Linux.Netlink

  @timeout 180_000

  # rkdeveloptool uses (bus << 8) + final port, not a full hub path. Capture
  # the unique sysfs topology now, before the board changes USB personality.
  def usb_path(location, root \\ "/sys/bus/usb/devices") do
    matches =
      for path <- Path.wildcard(Path.join(root, "*")),
          attribute(path, "idVendor") == "2207",
          attribute(path, "idProduct") == "350f",
          bus = attribute(path, "busnum"),
          ports = attribute(path, "devpath"),
          is_binary(bus) and is_binary(ports),
          {bus, ""} <- [Integer.parse(bus)],
          {port, ""} <- [ports |> String.split(".") |> List.last() |> Integer.parse()],
          String.downcase(location) ==
            Integer.to_string((bus <<< 8) + port, 16) |> String.downcase(),
          do: Path.basename(path)

    case matches do
      [path] -> path
      _ -> nil
    end
  end

  def wait(plan, report) do
    case Map.get(plan, :usb_path) do
      path when is_binary(path) ->
        report.(
          "Flash verified; waiting up to three minutes for USB reboot, DHCP and device information"
        )

        connection = await(fn timeout -> probe(path, plan.public.version, timeout) end, @timeout)

        if connection.status == :connected,
          do: :ok = Workbench.LANDiscovery.record_usb(connection.device)

        report.(connection.message)
        connection

      _ ->
        unavailable(:usb_tracking_unavailable)
    end
  rescue
    _ -> unavailable(:unavailable)
  catch
    :exit, _ -> unavailable(:unavailable)
  end

  @doc false
  def await(probe, timeout, interval \\ 1_000) do
    poll(probe, System.monotonic_time(:millisecond) + timeout, interval, :usb_not_ready)
  end

  defp poll(probe, deadline, interval, reason) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      unavailable(reason)
    else
      limit = min(remaining, 5_000)

      task =
        Task.async(fn ->
          try do
            probe.(limit)
          catch
            _, _ ->
              {:error,
               %{
                 code: "unavailable",
                 message: "Network control is unavailable. Reconnect and read the current state."
               }}
          end
        end)

      case Task.yield(task, limit) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, info}} ->
          %{status: :connected, device: info, message: "USB device information read"}

        {:ok, {:error, :firmware_mismatch}} ->
          unavailable(:firmware_mismatch)

        result ->
          reason =
            case result do
              {:ok, {:error, reason}} -> reason
              _ -> :unavailable
            end

          Process.sleep(max(min(interval, deadline - System.monotonic_time(:millisecond)), 0))
          poll(probe, deadline, interval, reason)
      end
    end
  end

  @doc false
  def probe(path, version, timeout) do
    with {:ok, addresses} <- :net.getifaddrs(:inet),
         [peer] <- peers(addresses, path),
         true <- direct_route?(peer),
         {:ok, %{status: 200, body: body}} <-
           Req.get(peer.url <> "/settings", request_options(peer, timeout)),
         {:ok, info} <- information(body, version),
         {:ok, current} <- :net.getifaddrs(:inet),
         [^peer] <- peers(current, path),
         true <- direct_route?(peer) do
      {:ok,
       Map.merge(peer, info)
       |> Map.drop([:local, :peer])
       |> Map.put(:read_at, DateTime.utc_now() |> DateTime.to_iso8601())
       |> Map.put(:usb_path, path)}
    else
      {:error, :firmware_mismatch} -> {:error, :firmware_mismatch}
      _ -> {:error, :usb_not_ready}
    end
  end

  @doc false
  def peers(addresses, path, root \\ "/sys/class/net") do
    for %{
          name: name,
          flags: flags,
          addr: %{addr: {a, b, c, d} = local},
          netmask: %{addr: {255, 255, 255, 252}}
        } <- addresses,
        a > 0 and a < 224 and a != 127 and rem(d, 4) in [1, 2],
        :up in flags and :running in flags,
        {:ok, device} <- [File.read_link(Path.join([root, to_string(name), "device"]))],
        String.starts_with?(Path.basename(device), path <> ":"),
        peer = {a, b, c, bxor(d, 3)},
        independent?(addresses, name, peer) do
      address = to_string(:inet.ntoa(peer))

      %{
        interface: to_string(name),
        local: local,
        peer: peer,
        address: address,
        url: "http://#{address}:4000"
      }
    end
    |> Enum.uniq()
  end

  defp independent?(addresses, name, peer) do
    Enum.all?(addresses, fn
      %{name: ^name} ->
        true

      %{addr: %{addr: address}, netmask: %{addr: mask}} ->
        (integer(address) &&& integer(mask)) != (integer(peer) &&& integer(mask))

      _ ->
        false
    end)
  end

  @doc false
  def direct_route?(%{interface: interface, local: local, peer: peer}) do
    with {:ok, index} <- :net.if_name2index(to_charlist(interface)) do
      body =
        <<2, 32, 32, 0, 0, 0, 0, 0, 0::native-32>> <>
          Netlink.attribute(1, <<integer(peer)::32>>) <>
          Netlink.attribute(2, <<integer(local)::32>>)

      case Netlink.request(26, 5, body) do
        {:ok, [{24, <<2, _::48, 1, _::32, attributes::binary>>}]} ->
          attributes = Netlink.attributes(attributes)
          attributes[4] == <<index::native-32>> and not Map.has_key?(attributes, 5)

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  @doc "Locate current, independent USB management peers without changing host networking."
  def usb_peers do
    with {:ok, addresses} <- :net.getifaddrs(:inet) do
      for path <- Enum.uniq(usb_paths()),
          peer <- peers(addresses, path),
          direct_route?(peer),
          do: Map.put(peer, :usb_path, path)
    else
      _ -> []
    end
  end

  @doc false
  def usb_paths(root \\ "/sys/class/net") do
    for interface <- Path.wildcard(Path.join(root, "*")),
        {:ok, device} <- [File.read_link(Path.join(interface, "device"))],
        [_, path] <- [
          Regex.run(~r/\A([0-9]+-[0-9]+(?:\.[0-9]+)*):[0-9]+\.[0-9]+\z/, Path.basename(device))
        ],
        do: path
  end

  def usb_peer!(address) do
    case Enum.filter(usb_peers(), &(&1.address == address)) do
      [peer] ->
        peer

      _ ->
        raise ArgumentError,
              "Select the gateway's directly connected USB IPv4 address. USB must have an independent /30 route; LAN or Tailscale access is not sufficient."
    end
  end

  def verify_usb!(peer) do
    unless usb_peer!(peer.address) == peer,
      do: raise("USB management path changed. Stop and review the device again.")

    :ok
  end

  # Read the existing device page, not a new unauthenticated command API or an
  # SSH session with automatically accepted host keys. Discard all other HTML,
  # including session tokens, key listings and private LiveView state.
  @doc false
  def information(body, expected_version) when is_binary(body) and byte_size(body) <= 1_048_576 do
    with {:ok, document} <- Floki.parse_document(body) do
      values =
        for row <- Floki.find(document, ".ui-setting-row"),
            label = row |> Floki.find("h3") |> Floki.text() |> String.trim(),
            label in ["Firmware", "Target", "Runtime"],
            value = row |> Floki.find(".ui-setting-value") |> Floki.text() |> String.trim(),
            byte_size(value) in 1..160,
            into: %{},
            do: {label, value}

      case values do
        %{"Firmware" => version, "Target" => "ec100", "Runtime" => runtime}
        when is_nil(expected_version) or version == expected_version ->
          {:ok, %{version: version, target: "ec100", runtime: runtime}}

        %{"Firmware" => _, "Target" => _} ->
          {:error, :firmware_mismatch}

        _ ->
          {:error, :invalid_information}
      end
    end
  end

  def information(_, _), do: {:error, :invalid_information}

  @doc false
  def request_options(peer, timeout) do
    [
      retry: false,
      redirect: false,
      raw: true,
      compressed: false,
      finch: [
        conn_opts: [transport_opts: [ip: peer.local, timeout: timeout]],
        receive_timeout: timeout,
        pool_timeout: timeout,
        request_timeout: timeout
      ],
      headers: [{"accept", "text/html"}, {"connection", "close"}],
      into: fn {:data, chunk}, {request, response} ->
        body = response.body || ""

        if byte_size(body) + byte_size(chunk) <= 1_048_576 do
          {:cont, {request, %{response | body: body <> chunk}}}
        else
          {:halt, {request, %{response | status: 413, body: ""}}}
        end
      end
    ]
  end

  defp unavailable(reason) do
    detail =
      case reason do
        :usb_tracking_unavailable ->
          "The reviewed USB port could not be tracked on this host."

        :firmware_mismatch ->
          "The USB device did not report the reviewed EC100 firmware version."

        _ ->
          "No matching USB device information was read before the deadline. Check boot, the USB cable and workstation DHCP."
      end

    %{
      status: :unavailable,
      message:
        "Flash verified; USB reconnection not confirmed. #{detail} No flash retry or networking change was made."
    }
  end

  defp attribute(path, name) do
    case File.read(Path.join(path, name)) do
      {:ok, value} -> String.trim(value)
      _ -> nil
    end
  end

  defp integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end

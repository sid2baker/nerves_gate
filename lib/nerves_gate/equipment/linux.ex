defmodule NervesGate.Equipment.Linux do
  @moduledoc "Kernel neighbor observations and an explicit bounded ARP-only scan. No IP port probes."
  import Bitwise
  alias NervesGate.Equipment.Subnet
  alias NervesGate.Linux.Netlink

  @behaviour NervesGate.Equipment.Adapter
  @impl true
  def load_labels(_) do
    NervesGate.Equipment.Labels.load()
  end

  @impl true
  def save_labels(labels, _) do
    NervesGate.Equipment.Labels.save(labels)
  end

  @impl true
  def neighbors(scope, _) do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(scope.interface)),
         {:ok, messages} <-
           Netlink.request(30, 0x301, <<2, 0, 0::16, index::native-32, 0::32>>) do
      now = System.system_time(:millisecond)

      entries =
        for {28, data} <- messages,
            entry = neighbor(data, index, now),
            entry != nil,
            Subnet.host?(scope, entry.ip) do
          entry
        end

      {:ok, Enum.take(entries, 256)}
    end
  end

  def neighbor(<<2, _::24, index::native-32, state::native-16, _::16, attrs::binary>>, index, now)
      when (state &&& 0xDE) != 0 do
    values = Netlink.attributes(attrs)

    with <<a, b, c, d>> <- values[1], <<_::48>> = mac <- values[2] do
      %{
        ip: "#{a}.#{b}.#{c}.#{d}",
        mac: mac_string(mac),
        last_seen: confirmed_at(values[3], state, now),
        source: "neighbor cache"
      }
    else
      _ -> nil
    end
  end

  def neighbor(_, _, _), do: nil

  @impl true
  def scan(scope, _) do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(scope.interface)),
         {:ok, mac} <- File.read("/sys/class/net/#{scope.interface}/address"),
         {:ok, mac} <- parse_mac(String.trim(mac)),
         {:ok, ip} <- NervesGate.Config.ipv4(scope.address),
         <<protocol::native-16>> = <<0x0806::16>>,
         {:ok, socket} <- :socket.open(17, :raw, protocol) do
      try do
        # sockaddr_ll; the socket is bound to this physical interface, never to
        # a default route. Bound sockets disappear when their worker exits.
        address = %{
          family: 17,
          addr: <<0x0806::16, index::native-32, 1::native-16, 0, 6, 0xFFFFFFFFFFFF::48, 0::16>>
        }

        with :ok <- :socket.bind(socket, address),
             do: scan_bound(socket, address, scope, mac, ip)
      after
        :socket.close(socket)
      end
    end
  end

  def request(mac, sender, target) do
    <<0xFFFFFFFFFFFF::48, mac::binary-size(6), 0x0806::16, 1::16, 0x0800::16, 6, 4, 1::16,
      mac::binary-size(6), Subnet.integer(sender)::32, 0::48, Subnet.integer(target)::32>>
  end

  def reply(
        <<_destination::48, _source::48, 0x0806::16, 1::16, 0x0800::16, 6, 4, 2::16,
          mac::binary-size(6), address::32, _target_mac::48, target::32, _::binary>>,
        scope
      ) do
    ip = Subnet.string(address)

    if Subnet.string(target) == scope.address and Subnet.host?(scope, ip),
      do: %{
        ip: ip,
        mac: mac_string(mac),
        last_seen: System.system_time(:millisecond),
        source: "ARP reply"
      }
  end

  def reply(_, _) do
    nil
  end

  defp scan_bound(socket, address, scope, mac, ip) do
    deadline = System.monotonic_time(:millisecond) + 5000

    result =
      Enum.reduce_while(Subnet.scan(scope).addresses, :ok, fn destination, :ok ->
        {:ok, target} = NervesGate.Config.ipv4(destination)
        remaining = deadline - System.monotonic_time(:millisecond)

        case send_probe(socket, address, request(mac, ip, target), remaining) do
          :ok ->
            Process.sleep(min(5, remaining))
            {:cont, :ok}

          error ->
            {:halt, error}
        end
      end)

    with :ok <- result do
      collect(socket, scope, %{}, deadline)
    end
  end

  defp send_probe(_, _, _, remaining) when remaining <= 0 do
    {:error, :timeout}
  end

  defp send_probe(socket, address, packet, remaining) do
    :socket.sendto(socket, packet, address, remaining)
  end

  defp collect(socket, scope, entries, deadline) do
    case :socket.recv(socket, 2048, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, packet} ->
        entries =
          case reply(packet, scope) do
            nil -> entries
            entry -> Map.put(entries, {entry.ip, entry.mac}, entry)
          end

        if map_size(entries) >= 256 or System.monotonic_time(:millisecond) >= deadline,
          do: {:ok, Map.values(entries)},
          else: collect(socket, scope, entries, deadline)

      {:error, :timeout} ->
        {:ok, Map.values(entries)}

      error ->
        error
    end
  end

  def parse_mac(mac) when is_binary(mac) do
    with true <- Regex.match?(~r/\A[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\z/, mac),
         {:ok, value} <- mac |> String.replace(":", "") |> Base.decode16(case: :mixed),
         <<first, _::binary>> <- value,
         true <- (first &&& 1) == 0 and value != <<0::48>>,
         do: {:ok, value},
         else: (_ -> {:error, :invalid_mac})
  end

  def parse_mac(_), do: {:error, :invalid_mac}

  defp mac_string(mac),
    do: for(<<byte <- mac>>, do: Base.encode16(<<byte>>, case: :lower)) |> Enum.join(":")

  # Linux's neighbor cache age uses USER_HZ (100), not the kernel tick rate.
  # Permanent/no-ARP entries are configuration, not proof of recent activity.
  defp confirmed_at(<<confirmed::native-32, _::binary>>, state, now) when (state &&& 0xC0) == 0,
    do: now - confirmed * 10

  defp confirmed_at(_, _, _), do: nil
end

defmodule NervesGate.Network.Connectivity do
  @moduledoc "Performs bounded, independent connectivity checks."

  @https_url ~c"https://controlplane.tailscale.com/key?v=1"
  @dns_name ~c"controlplane.tailscale.com"

  @type result :: %{
          physical_link: :ok | {:error, term()},
          ip_address: :ok | {:error, term()},
          default_route: :ok | {:error, term()},
          dns: :ok | {:error, term()},
          internet_https: :ok | {:error, term()},
          tailscale: :ok | :unknown | {:error, term()}
        }

  @spec verify(String.t(), keyword()) :: result()
  def verify(interface, options \\ []) do
    timeout = Keyword.get(options, :timeout, 3_000)

    %{
      physical_link: physical_link(interface),
      ip_address: ip_address(interface),
      default_route: default_route(interface),
      dns: bounded(&dns/0, timeout),
      internet_https: bounded(fn -> https(timeout) end, timeout + 500),
      tailscale: :unknown
    }
  end

  @spec internet_ready?(result()) :: boolean()
  def internet_ready?(checks) do
    Enum.all?(
      [:physical_link, :ip_address, :default_route, :dns, :internet_https],
      &(Map.fetch!(checks, &1) == :ok)
    )
  end

  defp physical_link(interface) do
    case File.read("/sys/class/net/#{interface}/carrier") do
      {:ok, value} -> if(String.trim(value) == "1", do: :ok, else: {:error, :no_carrier})
      {:error, :einval} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ip_address(interface) do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         {_name, properties} <- List.keyfind(interfaces, String.to_charlist(interface), 0),
         true <- Enum.any?(properties, &ipv4_property?/1) do
      :ok
    else
      _other -> {:error, :no_ipv4_address}
    end
  end

  defp ipv4_property?({:addr, {a, b, c, d}}),
    do: Enum.all?([a, b, c, d], &is_integer/1) and {a, b, c, d} != {127, 0, 0, 1}

  defp ipv4_property?(_property), do: false

  defp default_route(interface) do
    case File.read("/proc/net/route") do
      {:ok, routes} ->
        if default_route_present?(routes, interface),
          do: :ok,
          else: {:error, :missing_default_route}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_route_present?(routes, interface) do
    routes
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.any?(&default_route_line?(&1, interface))
  end

  defp default_route_line?(line, interface) do
    case String.split(line) do
      [^interface, "00000000", _gateway, flags | _rest] -> route_up?(flags)
      _fields -> false
    end
  end

  defp route_up?(hex_flags) do
    case Integer.parse(hex_flags, 16) do
      {flags, ""} -> Bitwise.band(flags, 0x1) == 0x1
      _other -> false
    end
  end

  defp dns do
    case :inet_res.gethostbyname(@dns_name, :inet) do
      {:ok, _hostent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp https(timeout) do
    http_options = [
      timeout: timeout,
      connect_timeout: timeout,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]

    case :httpc.request(:get, {@https_url, []}, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..499 -> :ok
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded(function, timeout) do
    task = Task.async(function)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, :check_failed}
    end
  end
end

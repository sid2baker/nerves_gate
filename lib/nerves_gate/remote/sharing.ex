defmodule NervesGate.Remote.Sharing do
  @moduledoc "Pure 4via6 addressing and admission. Site IDs must be assigned uniquely by the tailnet operator."
  import Bitwise
  alias NervesGate.Equipment.Subnet

  @prefix {0xFD7A, 0x115C, 0xA1E0, 0xB1A}

  def scope(%{config: %{"network" => %{"mode" => "ports"}}} = status),
    do: Subnet.active(status)

  def scope(_), do: {:error, :sharing_dedicated_only}

  def enable(status, remote, site, confirmed) do
    with :ok <- NervesGate.Remote.Policy.available(remote),
         :ok <- known(remote),
         :ok <- supported(remote),
         {:ok, scope} <- scope(status),
         {:ok, site} <- site_id(site),
         true <- confirmed == true do
      {:ok, %{scope: scope, route: route(scope, site)}}
    else
      false -> {:error, :sharing_confirmation}
      error -> error
    end
  end

  def known(%{sharing: %{uncertain: [], ready: true}}), do: :ok
  def known(_), do: {:error, :sharing_unknown}

  def supported(%{simulated: true}), do: :ok

  def supported(%{version: version}) when is_binary(version) do
    with [version | _] <- String.split(version, "-"),
         {:ok, version} <- Version.parse(version),
         true <- Version.compare(version, "1.102.3") != :lt do
      :ok
    else
      _ -> {:error, :sharing_version}
    end
  end

  def supported(_), do: {:error, :sharing_version}

  # Changes to LAN roles are forbidden while any 4via6 route is advertised,
  # including external routes. Independent rollback never uses this guard.
  def lan_change(remote) do
    with :ok <- known(remote),
         :ok <- NervesGate.Remote.Policy.available(remote),
         routes when is_list(routes) <- remote.advertised_routes,
         [] <- Enum.filter(routes, &via6?/1) do
      :ok
    else
      routes when is_list(routes) -> {:error, :sharing_active}
      _ -> {:error, :sharing_unknown}
    end
  end

  def site_id(site) when is_binary(site) do
    case Integer.parse(site) do
      {value, ""} -> site_id(value)
      _ -> {:error, :sharing_site_id}
    end
  end

  def site_id(site) when is_integer(site) and site in 0..65_535, do: {:ok, site}
  def site_id(_), do: {:error, :sharing_site_id}

  def route(scope, site),
    do: "#{address(Subnet.string(scope.network), site)}/#{96 + scope.prefix}"

  def address(ip, site) when site in 0..65_535 do
    {:ok, ip} = NervesGate.Config.ipv4(ip)
    value = Subnet.integer(ip)
    {a, b, c, d} = @prefix
    {a, b, c, d, 0, site, value >>> 16, value &&& 0xFFFF} |> :inet.ntoa() |> to_string()
  end

  def decode(route) when is_binary(route) do
    with [ip, mask] <- String.split(route, "/"),
         {prefix, ""} when prefix in 97..126 <- Integer.parse(mask),
         {:ok, {0xFD7A, 0x115C, 0xA1E0, 0xB1A, 0, site, hi, lo}} <-
           :inet.parse_ipv6strict_address(:binary.bin_to_list(ip)),
         value = hi <<< 16 ||| lo,
         true <- (value >>> (128 - prefix)) <<< (128 - prefix) == value do
      {:ok,
       %{
         site: site,
         network: value,
         prefix: prefix - 96,
         cidr: "#{Subnet.string(value)}/#{prefix - 96}"
       }}
    else
      _ -> {:error, :sharing_route}
    end
  end

  def decode(_), do: {:error, :sharing_route}

  def via6?(route) when is_binary(route) do
    with [ip, mask] <- String.split(route, "/"),
         {prefix, ""} when prefix in 0..128 <- Integer.parse(mask),
         {:ok, tuple} when tuple_size(tuple) == 8 <-
           :inet.parse_ipv6strict_address(:binary.bin_to_list(ip)) do
      value = tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc <<< 16 ||| part end)
      base = 336_928_495_290_377_116_596_537_062_994_776_948_736
      shift = 128 - min(prefix, 64)
      value >>> shift == base >>> shift
    else
      _ -> false
    end
  end

  def via6?(_) do
    false
  end

  def matches?(route, scope) when is_map(scope) do
    case decode(route) do
      {:ok, decoded} -> decoded.network == scope.network and decoded.prefix == scope.prefix
      _ -> false
    end
  end

  def matches?(_, _), do: false

  def validate_routes(routes, scope) when is_list(routes) do
    if routes |> Enum.filter(&via6?/1) |> Enum.all?(&matches?(&1, scope)) do
      :ok
    else
      {:error, :sharing_stale}
    end
  end

  def validate_routes(_, _) do
    {:error, :sharing_unknown}
  end
end

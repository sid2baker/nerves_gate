defmodule NervesGate.Config do
  @moduledoc "Pure network input validation and port-role helpers. Persistence belongs to VintageNet."
  import Bitwise

  def defaults, do: from_network(%{"mode" => "unconfigured"})

  def from_network(network),
    do: %{"setup_completed" => network["mode"] != "unconfigured", "network" => network}

  @doc "Internet policy is independent of the Ethernet topology; Ethernet is the default."
  def internet(network), do: (network && network["internet"]) || %{"mode" => "ethernet"}
  def cellular?(network), do: internet(network)["mode"] in ["cellular", "backup"]

  def validate_network(network) when is_map(network) do
    with {:ok, ethernet} <- validate_ethernet(Map.delete(network, "internet")),
         :ok <- validate_internet(Map.merge(ethernet, Map.take(network, ["internet"]))) do
      {:ok, Map.merge(ethernet, Map.take(network, ["internet"]))}
    end
  end

  def validate_network(_), do: {:error, "Network settings must be an object."}

  defp validate_internet(%{"internet" => %{"mode" => "ethernet"} = internet})
       when map_size(internet) == 1, do: :ok

  defp validate_internet(%{"internet" => %{"mode" => mode, "apn" => apn} = internet} = network)
       when mode in ["cellular", "backup"] and map_size(internet) in [2, 3] do
    cond do
      not valid_internet_fields?(internet) ->
        {:error, "Choose a valid carrier profile or Automatic."}

      not valid_apn?(apn) ->
        {:error,
         "Leave APN blank for the network default, or enter the operator's APN (up to 100 letters, digits, dots or hyphens)."}

      network["mode"] == "unconfigured" ->
        {:error, "Choose your Ethernet port arrangement before enabling cellular."}

      true ->
        validate_cellular_uplink(network, mode)
    end
  end

  defp validate_internet(%{"internet" => _}),
    do: {:error, "Choose Ethernet, 4G, or Ethernet with 4G backup."}

  defp validate_internet(_), do: :ok

  defp validate_cellular_uplink(network, mode) do
    case {mode, ethernet_uplink?(network)} do
      {"cellular", true} ->
        {:error, "4G-only mode cannot have an Ethernet Internet assignment."}

      {"backup", false} ->
        {:error, "Choose an Ethernet Internet port for 4G backup."}

      _ ->
        :ok
    end
  end

  defp valid_internet_fields?(internet) do
    Enum.all?(Map.keys(internet), &(&1 in ["mode", "apn", "provider"])) and
      (not Map.has_key?(internet, "provider") or valid_provider?(internet["provider"]))
  end

  defp valid_provider?(id), do: is_binary(id) and Regex.match?(~r/\A[a-f0-9]{64}\z/, id)

  defp valid_apn?(""), do: true

  defp valid_apn?(apn),
    do: is_binary(apn) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,99}\z/, apn)

  defp ethernet_uplink?(network),
    do: role_port(network, "internet") != nil

  def address_defaults do
    %{"ip_method" => "dhcp", "static_ip" => nil, "subnet_mask" => nil, "gateway" => nil}
  end

  defp validate_ethernet(%{"mode" => "unconfigured"} = network) when map_size(network) == 1 do
    {:ok, network}
  end

  defp validate_ethernet(%{"mode" => "ports", "eth0" => left, "eth1" => right} = network)
       when map_size(network) == 3 do
    with {:ok, left} <- validate_port(left),
         {:ok, right} <- validate_port(right),
         true <-
           is_nil(left) or is_nil(right) or left["role"] != right["role"] or
             left["role"] == "application" do
      {:ok, %{network | "eth0" => left, "eth1" => right}}
    else
      _ ->
        {:error,
         "Use at most one Internet port; other ports must be disabled or application-enabled. Legacy equipment and joined settings require explicit administrator migration; saved state is never rewritten."}
    end
  end

  defp validate_ethernet(_) do
    {:error,
     "Choose independent Internet/application ports. Legacy equipment and joined networks require explicit administrator migration; saved state is never rewritten."}
  end

  defp validate_port(nil), do: {:ok, nil}

  defp validate_port(%{"role" => "application", "address" => nil} = port)
       when map_size(port) == 2,
       do: {:ok, port}

  defp validate_port(%{"role" => "internet", "address" => address} = port)
       when map_size(port) == 2 do
    case validate_address(address) do
      {:ok, address} -> {:ok, %{port | "address" => address}}
      _ -> {:error, :invalid_port}
    end
  end

  defp validate_port(_), do: {:error, :invalid_port}

  @doc "Explicit port assignments."
  def ports(%{"mode" => "ports"} = network), do: Map.take(network, ["eth0", "eth1"])

  def ports(_), do: %{"eth0" => nil, "eth1" => nil}

  def role_port(network, role) do
    Enum.find_value(ports(network), fn {name, port} ->
      if port && port["role"] == role, do: name
    end)
  end

  def role_address(network, role) do
    case role_port(network, role) do
      nil -> nil
      name -> ports(network)[name]["address"]
    end
  end

  def validate_address(network) when is_map(network) do
    allowed = ["ip_method", "static_ip", "subnet_mask", "gateway", "nameservers"]

    cond do
      Enum.any?(Map.keys(network), &(&1 not in allowed)) ->
        {:error, "Unknown Ethernet setting."}

      network["ip_method"] == "dhcp" ->
        {:ok, address_defaults()}

      network["ip_method"] == "static" ->
        with {:ok, address} <- validate_static(network),
             :ok <- validate_nameservers(Map.get(network, "nameservers", [])) do
          {:ok,
           if Map.has_key?(network, "nameservers") do
             Map.put(address, "nameservers", network["nameservers"])
           else
             address
           end}
        end

      true ->
        {:error, "Choose automatic or manual IP addressing."}
    end
  end

  def validate_address(_), do: {:error, "Ethernet settings must be an object."}

  defp validate_nameservers(servers) do
    bounded_list =
      match?([], servers) or match?([_], servers) or match?([_, _], servers) or
        match?([_, _, _], servers)

    if bounded_list and Enum.all?(servers, &valid_nameserver?/1),
      do: :ok,
      else: {:error, "Enter up to three IPv4 DNS server addresses."}
  end

  defp valid_nameserver?(server) do
    case ipv4(server) do
      {:ok, ip} -> unicast?(ip)
      _ -> false
    end
  end

  @doc "Compare IPv4 subnets, including differently sized prefixes."
  def overlap?(address, prefix, other, other_prefix)
      when prefix in 0..32 and other_prefix in 0..32 do
    with {:ok, ip} <- ipv4(address), {:ok, other_ip} <- ipv4(other) do
      mask = mask_integer(min(prefix, other_prefix))
      (integer(ip) &&& mask) == (integer(other_ip) &&& mask)
    else
      _ -> false
    end
  end

  def overlap?(_, _, _, _), do: false

  defp validate_static(network) do
    gateway = blank_to_nil(network["gateway"])

    with {:ok, ip} <- ipv4(network["static_ip"]),
         true <- unicast?(ip),
         {:ok, prefix} <- prefix_length(network["subnet_mask"]),
         true <- host_address?(ip, prefix),
         :ok <- validate_gateway(gateway, ip, prefix) do
      {:ok,
       %{
         "ip_method" => "static",
         "static_ip" => ip_string(ip),
         "subnet_mask" => network["subnet_mask"],
         "gateway" => gateway
       }}
    else
      _ ->
        {:error,
         "Enter a usable IPv4 address and contiguous subnet mask (/1–/30). The optional gateway must be a different host on the same subnet."}
    end
  end

  def ipv4(value) when is_binary(value) do
    with true <- String.valid?(value),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(value)) do
      {:ok, ip}
    else
      _ -> {:error, :invalid_ipv4}
    end
  end

  def ipv4(_), do: {:error, :invalid_ipv4}

  def prefix_length(mask) do
    with {:ok, tuple} <- ipv4(mask),
         bits = integer(tuple),
         prefix when is_integer(prefix) <- Enum.find(1..30, &(mask_integer(&1) == bits)) do
      {:ok, prefix}
    else
      _ -> {:error, :invalid_mask}
    end
  end

  defp validate_gateway(nil, _, _), do: :ok

  defp validate_gateway(gateway, ip, prefix) do
    with {:ok, gw} <- ipv4(gateway),
         true <- unicast?(gw) and gw != ip and host_address?(gw, prefix),
         true <- (integer(gw) &&& mask_integer(prefix)) == (integer(ip) &&& mask_integer(prefix)) do
      :ok
    else
      _ -> {:error, :invalid_gateway}
    end
  end

  defp unicast?({a, _, _, _}), do: a > 0 and a < 224 and a != 127

  defp host_address?(ip, prefix),
    do: (integer(ip) &&& 0xFFFFFFFF >>> prefix) not in [0, 0xFFFFFFFF >>> prefix]

  defp integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp mask_integer(prefix), do: 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF
  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end

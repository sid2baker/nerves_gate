defmodule NervesGateWeb.NetworkForm do
  @moduledoc false
  alias NervesGate.Config
  alias NervesGate.Network.Suggestions, as: Suggestions

  def from_settings(network, :internet) do
    fresh = network && network["mode"] == "unconfigured"
    internet = Config.internet(network)

    %{
      "internet_mode" => internet["mode"],
      "cellular_apn" => internet["apn"] || "",
      "cellular_profile" => profile(internet),
      "internet_port" => if(fresh, do: "auto", else: Config.role_port(network, "internet") || "")
    }
    |> put_address("internet", Config.role_address(network, "internet"))
  end

  def internet_port(%{"internet_mode" => "cellular"}, _), do: nil
  def internet_port(%{"internet_port" => "auto"}, ports), do: Suggestions.internet_port(ports)
  def internet_port(params, _), do: blank(params["internet_port"])

  def to_network(params, ports, base, :internet) when is_map(base) do
    internet = internet_port(params, ports)

    cond do
      ambiguous_internet?(params, ports, internet) ->
        {:error,
         "More than one network is connected. Choose an Internet port, or choose Not now."}

      internet not in [nil, "eth0", "eth1"] ->
        {:error, "Choose LAN 1, LAN 2, or Not now."}

      true ->
        with {:ok, _} <- Config.validate_network(base) do
          base
          |> application_ports()
          |> assign_port(internet, "internet", address(params, "internet"))
          |> validate(params)
        end
    end
  end

  def to_network(_, _, _, _), do: {:error, "Choose valid network settings."}

  def defaults_for_change(params, previous, :internet, observed) do
    params = carrier_change(params, previous)
    prefix = "internet"

    if previous["#{prefix}_method"] != "static" and params["#{prefix}_method"] == "static",
      do: static_defaults(params, prefix, observed),
      else: params
  end

  defp application_ports(base) do
    Enum.reduce(Config.ports(base), %{"mode" => "ports", "eth0" => nil, "eth1" => nil}, fn {name,
                                                                                            port},
                                                                                           acc ->
      if port && port["role"] == "application", do: Map.put(acc, name, port), else: acc
    end)
  end

  defp ambiguous_internet?(params, ports, internet) do
    candidates = Enum.count(ports, &(&1.link and Map.get(&1, :addresses, []) != []))

    params["internet_mode"] != "cellular" and params["internet_port"] == "auto" and
      is_nil(internet) and candidates > 1
  end

  defp validate(network, params) do
    internet = %{
      "mode" => params["internet_mode"] || "ethernet",
      "apn" => String.trim(params["cellular_apn"] || "")
    }

    internet =
      case params["cellular_profile"] do
        "provider:" <> id -> Map.put(internet, "provider", id)
        _ -> internet
      end

    network =
      if internet["mode"] == "ethernet", do: network, else: Map.put(network, "internet", internet)

    Config.validate_network(network)
  end

  defp profile(%{"provider" => id}), do: "provider:" <> id
  defp profile(%{"apn" => apn}) when apn not in [nil, ""], do: "custom"
  defp profile(_), do: "auto"

  defp carrier_change(params, previous) do
    case {params["cellular_profile"], previous["cellular_profile"]} do
      {same, same} ->
        params

      {"auto", _} ->
        Map.put(params, "cellular_apn", "")

      {"provider:" <> id, _} ->
        case NervesGate.Cellular.Providers.option(id) do
          nil -> params
          option -> Map.put(params, "cellular_apn", option["apn"])
        end

      _ ->
        params
    end
  end

  defp assign_port(network, nil, _, _), do: network

  defp assign_port(network, name, role, address),
    do: Map.put(network, name, %{"role" => role, "address" => address})

  defp put_address(params, prefix, address) do
    address = address || %{}

    Enum.reduce(
      %{
        "method" => address["ip_method"] || "dhcp",
        "ip" => address["static_ip"] || "",
        "mask" => address["subnet_mask"] || "255.255.255.0",
        "gateway" => address["gateway"] || "",
        "dns" => Enum.join(Map.get(address, "nameservers", []), ", ")
      },
      params,
      fn {key, value}, acc -> Map.put(acc, "#{prefix}_#{key}", value) end
    )
  end

  defp address(params, prefix) do
    %{
      "ip_method" => params[prefix <> "_method"],
      "static_ip" => params[prefix <> "_ip"],
      "subnet_mask" => params[prefix <> "_mask"],
      "gateway" => params[prefix <> "_gateway"],
      "nameservers" => String.split(params[prefix <> "_dns"] || "", ~r/[\s,]+/, trim: true)
    }
  end

  def static_defaults(params, prefix, observed) do
    if params[prefix <> "_ip"] in [nil, ""] do
      observed = observed || %{ports: [], bridge: nil, usb: nil}

      name = internet_port(params, observed.ports)
      interface = Enum.find(observed.ports, &(&1.name == name))

      defaults = observed_defaults(interface) || example_defaults(prefix, name, observed)

      Enum.reduce(defaults, params, fn {key, value}, acc ->
        put_default(acc, prefix, key, value)
      end)
    else
      params
    end
  end

  defp observed_defaults(nil) do
    nil
  end

  defp observed_defaults(interface) do
    case Enum.find(Map.get(interface, :addresses, []), &(&1.prefix_length in 1..30)) do
      nil ->
        nil

      address ->
        %{
          "ip" => address.address,
          "mask" => mask(address.prefix_length),
          "gateway" => Map.get(interface, :gateway) || "",
          "dns" => Enum.join(Map.get(interface, :nameservers, []), ", ")
        }
    end
  end

  defp example_defaults(prefix, name, observed) do
    ip = fallback_address(prefix, name, observed)

    gateway = String.replace_suffix(ip, ".2", ".1")

    %{"ip" => ip, "mask" => "255.255.255.0", "gateway" => gateway, "dns" => gateway}
  end

  defp put_default(params, prefix, key, value) do
    field = prefix <> "_" <> key

    if params[field] in [nil, ""] or key == "mask" do
      Map.put(params, field, value)
    else
      params
    end
  end

  defp fallback_address(_prefix, name, observed) do
    candidates = ["192.168.1.2", "192.168.10.2", "10.42.0.2", "172.22.0.2"]

    addresses =
      (Enum.reject(observed.ports, &(&1.name == name)) ++ [observed.usb])
      |> Enum.flat_map(fn interface ->
        (interface && Map.get(interface, :addresses, [])) || []
      end)

    Enum.find(candidates, "", fn ip ->
      not Enum.any?(addresses, &Config.overlap?(ip, 24, &1.address, &1.prefix_length))
    end)
  end

  defp mask(prefix) do
    bits = Bitwise.band(Bitwise.bsl(4_294_967_295, 32 - prefix), 4_294_967_295)
    <<a, b, c, d>> = <<bits::32>>
    Enum.join([a, b, c, d], ".")
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end

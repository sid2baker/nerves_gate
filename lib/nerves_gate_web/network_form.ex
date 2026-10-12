defmodule NervesGateWeb.NetworkForm do
  @moduledoc false
  alias NervesGate.{Config, Network.Discovery}

  def from_settings(network) do
    fresh = network && network["mode"] == "unconfigured"
    internet = Config.internet(network)

    %{
      "mode" => if(network && network["mode"] == "shared", do: "shared", else: "ports"),
      "internet_mode" => internet["mode"],
      "cellular_apn" => internet["apn"] || "",
      "internet_port" => if(fresh, do: "auto", else: Config.role_port(network, "internet") || ""),
      "equipment_port" => Config.role_port(network, "equipment") || ""
    }
    |> put_address("internet", Config.role_address(network, "internet"))
    |> put_address("equipment", Config.role_address(network, "equipment"))
    |> put_address("shared", network && network["equipment"])
  end

  def internet_port(%{"internet_mode" => "cellular"}, _), do: nil
  def internet_port(%{"internet_port" => "auto"}, ports), do: Discovery.internet_port(ports)
  def internet_port(params, _), do: blank(params["internet_port"])

  def to_network(%{"mode" => "shared"} = params, _ports) do
    validate(%{"mode" => "shared", "equipment" => address(params, "shared")}, params)
  end

  def to_network(%{"mode" => "ports"} = params, ports) do
    internet = internet_port(params, ports)
    equipment = blank(params["equipment_port"])

    cond do
      ambiguous_internet?(params, ports, internet) ->
        {:error,
         "More than one network is connected. Choose an Internet port, or choose Not now."}

      same_port?(internet, equipment) ->
        {:error,
         "Internet and equipment need different ports. Choose a different equipment port."}

      internet not in [nil, "eth0", "eth1"] or equipment not in [nil, "eth0", "eth1"] ->
        {:error, "Choose Port 1, Port 2, or Not now."}

      true ->
        network = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
        network = assign_port(network, internet, "internet", address(params, "internet"))
        network = assign_port(network, equipment, "equipment", address(params, "equipment"))
        validate(network, params)
    end
  end

  def to_network(_, _), do: {:error, "Choose separate ports or one shared network."}

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

    network =
      if internet["mode"] == "ethernet", do: network, else: Map.put(network, "internet", internet)

    Config.validate_network(network)
  end

  defp same_port?(internet, equipment), do: internet != nil and internet == equipment

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

  defp address(params, "equipment") do
    %{
      "ip_method" => "static",
      "static_ip" => params["equipment_ip"],
      "subnet_mask" => params["equipment_mask"],
      "gateway" => nil
    }
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

      name =
        if prefix == "internet" do
          internet_port(params, observed.ports)
        else
          params["equipment_port"]
        end

      interface =
        if prefix == "shared" do
          observed.bridge
        else
          Enum.find(observed.ports, &(&1.name == name))
        end

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

    gateway =
      if prefix == "equipment" do
        ""
      else
        String.replace_suffix(ip, ".2", ".1")
      end

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

  defp fallback_address(prefix, name, observed) do
    candidates =
      if prefix == "equipment" do
        ["192.168.10.2", "192.168.20.2", "10.42.0.2", "172.22.0.2"]
      else
        ["192.168.1.2", "192.168.10.2", "10.42.0.2", "172.22.0.2"]
      end

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

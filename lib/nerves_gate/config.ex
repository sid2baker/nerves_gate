defmodule NervesGate.Config do
  @moduledoc "Validated, versioned settings. Runtime status and credentials never go in this file."
  import Bitwise

  def path, do: Path.join(Application.fetch_env!(:nerves_gate, :data_dir), "nerves_gate.json")

  def defaults do
    %{
      "version" => 2,
      "setup_completed" => false,
      "network" => %{"mode" => "unconfigured"},
      "mobile" => %{"enabled" => true, "apn" => "auto"},
      "vpn" => %{"enabled" => false}
    }
  end

  def load(path \\ path()) do
    case File.read(path) do
      {:ok, json} ->
        with {:ok, config} <- Jason.decode(json), do: validate(config)

      {:error, :enoent} ->
        {:ok, defaults()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Preserve an installed v1 gateway's shared network. Migration is in memory;
  # only an explicit trial/confirmation writes the new format.
  def validate(%{"version" => 1} = config) do
    with {:ok, address} <- validate_address(config["network"]) do
      validate(%{
        config
        | "version" => 2,
          "network" => %{"mode" => "shared", "equipment" => address}
      })
    end
  end

  def validate(config) when is_map(config) do
    with true <- Enum.sort(Map.keys(config)) == Enum.sort(Map.keys(defaults())),
         2 <- config["version"],
         true <- is_boolean(config["setup_completed"]),
         {:ok, network} <- validate_network(config["network"]),
         %{"enabled" => enabled, "apn" => apn} = mobile <- config["mobile"],
         true <- map_size(mobile) == 2 and is_boolean(enabled) and is_binary(apn),
         true <- byte_size(apn) in 1..100 and Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, apn),
         %{"enabled" => vpn_enabled} = vpn <- config["vpn"],
         true <- map_size(vpn) == 1 and is_boolean(vpn_enabled) do
      {:ok, %{config | "network" => network}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid or unsupported configuration (expected version 2)."}
    end
  end

  def validate(_), do: {:error, "Configuration must be a JSON object."}

  def address_defaults do
    %{"ip_method" => "dhcp", "static_ip" => nil, "subnet_mask" => nil, "gateway" => nil}
  end

  def validate_network(%{"mode" => "unconfigured"} = network) when map_size(network) == 1,
    do: {:ok, network}

  def validate_network(%{"mode" => "shared", "equipment" => address} = network)
      when map_size(network) == 2 do
    with {:ok, address} <- validate_address(address) do
      {:ok, %{network | "equipment" => address}}
    end
  end

  def validate_network(
        %{"mode" => "ethernet", "internet_port" => port, "equipment" => equipment} = network
      )
      when map_size(network) == 3 and port in ["eth0", "eth1"] do
    with {:ok, %{"ip_method" => "static", "gateway" => nil} = address} <-
           validate_address(equipment) do
      {:ok, %{network | "equipment" => address}}
    else
      _ ->
        {:error,
         "Choose an unused manual address in the equipment network, without a router address. Equipment addresses are not changed."}
    end
  end

  def validate_network(_),
    do:
      {:error,
       "Choose separate Internet and equipment ports, or explicitly choose one shared network."}

  def validate_address(network) when is_map(network) do
    allowed = ["ip_method", "static_ip", "subnet_mask", "gateway"]

    cond do
      Enum.any?(Map.keys(network), &(&1 not in allowed)) ->
        {:error, "Unknown Ethernet setting."}

      network["ip_method"] == "dhcp" ->
        {:ok, address_defaults()}

      network["ip_method"] == "static" ->
        validate_static(network)

      true ->
        {:error, "Choose automatic or manual IP addressing."}
    end
  end

  def validate_address(_), do: {:error, "Ethernet settings must be an object."}

  def equipment_port(%{"internet_port" => "eth0"}), do: "eth1"
  def equipment_port(%{"internet_port" => "eth1"}), do: "eth0"

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
    case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
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

  @doc "Write a validated file atomically. Never replace a working file with partial JSON."
  def save(config, path \\ path()) do
    with {:ok, normalized} <- validate(config),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      try do
        with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary, :raw]) do
          result =
            try do
              with :ok <- File.chmod(temporary, 0o600),
                   :ok <- :file.write(file, Jason.encode!(normalized, pretty: true) <> "\n") do
                :file.sync(file)
              end
            after
              File.close(file)
            end

          with :ok <- result, :ok <- File.rename(temporary, path) do
            # Rename is the commit point. Directory sync improves power-loss durability.
            sync_directory(Path.dirname(path))
            :ok
          end
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        :file.sync(directory)
        :file.close(directory)

      _ ->
        :ok
    end
  end
end

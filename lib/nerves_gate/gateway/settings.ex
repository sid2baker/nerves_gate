defmodule NervesGate.Gateway.Settings do
  @moduledoc "Validated private settings stored in firmware-slot snapshots."

  import Bitwise

  alias NervesGate.Cluster, as: Cluster
  alias NervesGate.Identity
  alias NervesGate.Internet.Config

  @slots ["a", "b"]

  @spec validate(map()) :: {:ok, map()} | {:error, term()}
  def validate(
        %{
          "version" => 1,
          "firmware" => %{
            "slot" => slot,
            "uuid" => uuid,
            "version" => firmware_version
          },
          "revision" => revision,
          "configured" => configured,
          "internet" => persisted_internet,
          "tailnet" => %{"profile_id" => profile_id},
          "cluster" => %{"group" => group},
          "name" => name
        } = settings
      )
      when slot in @slots and is_binary(uuid) and is_binary(firmware_version) and
             is_integer(revision) and revision >= 0 and is_boolean(configured) and
             (is_binary(profile_id) or is_nil(profile_id)) do
    with :ok <- validate_profile_id(profile_id, configured),
         :ok <- validate_updated_at(Map.get(settings, "updated_at")),
         {:ok, internet} <- validate_internet(persisted_internet, configured),
         {:ok, subnet_router} <- validate_subnet_router(Map.get(settings, "subnet_router")),
         {:ok, ssh_enabled} <- validate_ssh_enabled(Map.get(settings, "ssh_enabled", false)),
         {:ok, group} <- Cluster.validate_group(group),
         {:ok, name} <- valid_name(name) do
      {:ok,
       settings
       |> Map.take([
         "version",
         "firmware",
         "revision",
         "configured",
         "updated_at",
         "internet",
         "tailnet",
         "subnet_router",
         "ssh_enabled",
         "cluster",
         "name"
       ])
       |> Map.put("internet", if(internet, do: Config.to_persisted(internet)))
       |> Map.put("tailnet", %{"profile_id" => profile_id})
       |> Map.put("subnet_router", subnet_router)
       |> Map.put("ssh_enabled", ssh_enabled)
       |> Map.put("cluster", %{"group" => group})
       |> Map.put("name", name)
       |> Map.put_new("updated_at", nil)}
    end
  end

  def validate(_settings), do: {:error, :invalid_settings}

  @spec default(map()) :: map()
  def default(firmware) do
    %{
      "version" => 1,
      "firmware" => firmware,
      "revision" => 0,
      "configured" => false,
      "updated_at" => nil,
      "internet" => nil,
      "tailnet" => %{"profile_id" => nil},
      "subnet_router" => default_subnet_router(),
      "ssh_enabled" => false,
      "cluster" => %{"group" => nil},
      "name" => Identity.get().hostname
    }
  end

  @spec build_internet(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_internet(current, params) do
    internet_params = Map.get(params, "internet", %{})
    name = params |> get_in(["device", "name"]) || current["name"]

    with {:ok, internet} <- Config.new(normalize_internet(internet_params)),
         {:ok, name} <- valid_name(name) do
      {:ok,
       bump(current, %{
         "internet" => Config.to_persisted(internet),
         "name" => name
       })}
    end
  end

  @spec public(map()) :: map()
  def public(settings) do
    %{
      firmware: settings["firmware"],
      revision: settings["revision"],
      configured: settings["configured"],
      updated_at: settings["updated_at"],
      internet: Config.to_public(internet(settings)),
      tailnet_configured: is_binary(tailnet_profile(settings)),
      subnet_router: public_subnet_router(settings),
      ssh_enabled: ssh_enabled(settings),
      cluster_group: cluster_group(settings),
      name: settings["name"]
    }
  end

  @spec bump(map(), map()) :: map()
  def bump(settings, changes) do
    settings
    |> Map.merge(changes)
    |> Map.update!("revision", &(&1 + 1))
    |> touch()
  end

  @spec touch(map()) :: map()
  def touch(settings) do
    Map.put(
      settings,
      "updated_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end

  @spec internet(map()) :: Config.t() | nil
  def internet(%{"internet" => nil}), do: nil

  def internet(%{"internet" => persisted}) do
    {:ok, config} = Config.from_persisted(persisted)
    config
  end

  def tailnet_profile(settings), do: get_in(settings, ["tailnet", "profile_id"])
  def subnet_router(settings), do: Map.get(settings, "subnet_router", default_subnet_router())
  def subnet_routes(settings), do: subnet_router(settings)["routes"]
  def ssh_enabled(settings), do: Map.get(settings, "ssh_enabled", false)
  def cluster_group(settings), do: get_in(settings, ["cluster", "group"])

  @spec validate_subnet_router(term()) :: {:ok, map()} | {:error, term()}
  def validate_subnet_router(nil), do: {:ok, default_subnet_router()}

  def validate_subnet_router(%{"enabled" => enabled, "routes" => routes} = subnet_router)
      when is_boolean(enabled) and is_list(routes) do
    with true <- Enum.count_until(routes, 33) <= 32,
         {:ok, routes} <- normalize_routes(routes) do
      {:ok,
       subnet_router
       |> Map.take(["enabled", "routes"])
       |> Map.put("routes", routes)}
    else
      _invalid -> {:error, :invalid_subnet_routes}
    end
  end

  def validate_subnet_router(_subnet_router), do: {:error, :invalid_subnet_router}

  def require_enabled_routes(%{"enabled" => true, "routes" => []}),
    do: {:error, :subnet_routes_required}

  def require_enabled_routes(_subnet_router), do: :ok

  def validate_auth_token(nil, %{"tailnet" => %{"profile_id" => id}}) when is_binary(id),
    do: :ok

  def validate_auth_token(token, _current)
      when is_binary(token) and byte_size(token) in 8..512,
      do: :ok

  def validate_auth_token(nil, _current), do: {:error, :tailscale_auth_key_required}
  def validate_auth_token(_token, _current), do: {:error, :invalid_auth_token}

  defp public_subnet_router(settings) do
    subnet_router = subnet_router(settings)
    %{enabled: subnet_router["enabled"], routes: subnet_router["routes"]}
  end

  defp validate_ssh_enabled(enabled) when is_boolean(enabled), do: {:ok, enabled}
  defp validate_ssh_enabled(_enabled), do: {:error, :invalid_ssh_enabled}

  defp validate_profile_id(nil, false), do: :ok
  defp validate_profile_id(nil, true), do: {:error, :tailnet_profile_required}

  defp validate_profile_id(profile_id, _configured)
       when is_binary(profile_id) and byte_size(profile_id) in 1..512,
       do: :ok

  defp validate_profile_id(_profile_id, _configured), do: {:error, :invalid_tailnet_profile}

  defp validate_updated_at(nil), do: :ok

  defp validate_updated_at(updated_at) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, _datetime, _offset} -> :ok
      {:error, _reason} -> {:error, :invalid_updated_at}
    end
  end

  defp validate_updated_at(_updated_at), do: {:error, :invalid_updated_at}

  defp validate_internet(nil, false), do: {:ok, nil}
  defp validate_internet(nil, true), do: {:error, :internet_configuration_required}
  defp validate_internet(settings, _configured), do: Config.from_persisted(settings)

  defp normalize_routes(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route, {:ok, normalized} ->
      case normalize_route(route) do
        {:ok, route} -> {:cont, {:ok, [route | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end)
  end

  defp normalize_route(route) when is_binary(route) and byte_size(route) in 3..128 do
    with [address, prefix] <- String.split(String.trim(route), "/", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(prefix),
         true <- prefix in prefix_range(address) do
      {:ok, canonical_prefix(address, prefix)}
    else
      _invalid -> :error
    end
  end

  defp normalize_route(_route), do: :error

  defp prefix_range(address) when tuple_size(address) == 4, do: 0..32
  defp prefix_range(address) when tuple_size(address) == 8, do: 0..128

  defp canonical_prefix(address, prefix_length) do
    segments = Tuple.to_list(address)
    segment_bits = if tuple_size(address) == 4, do: 8, else: 16
    total_bits = tuple_size(address) * segment_bits
    host_bits = total_bits - prefix_length

    address_integer =
      Enum.reduce(segments, 0, fn segment, value ->
        value <<< segment_bits ||| segment
      end)

    network_integer = (address_integer >>> host_bits) <<< host_bits

    network_address =
      total_bits
      |> segment_shifts(segment_bits)
      |> Enum.map(&(network_integer >>> &1 &&& (1 <<< segment_bits) - 1))
      |> List.to_tuple()
      |> :inet.ntoa()
      |> to_string()

    "#{network_address}/#{prefix_length}"
  end

  defp segment_shifts(total_bits, segment_bits) do
    Stream.iterate(total_bits - segment_bits, &(&1 - segment_bits))
    |> Enum.take(div(total_bits, segment_bits))
  end

  defp normalize_internet(params) do
    params = stringify_keys(params)
    ip_address = params["ip_address"]
    method = params["method"] || if(ip_address in [nil, "", "dhcp"], do: "dhcp", else: "static")

    params
    |> Map.put_new("interface", "eth0")
    |> Map.put_new("kind", "ethernet")
    |> Map.put("method", method)
    |> maybe_put("address", ip_address)
    |> copy_key("dns", "dns_primary")
  end

  defp stringify_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp maybe_put(params, _key, value) when value in [nil, "", "dhcp"], do: params
  defp maybe_put(params, key, value), do: Map.put_new(params, key, value)

  defp copy_key(params, source, destination) do
    case params[source] do
      nil -> params
      value -> Map.put_new(params, destination, value)
    end
  end

  defp valid_name(name) when is_binary(name) do
    name = String.trim(name)

    if byte_size(name) in 1..80 and String.printable?(name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}
  defp default_subnet_router, do: %{"enabled" => false, "routes" => []}
end

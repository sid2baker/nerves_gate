defmodule NervesGate.Internet.Config do
  @moduledoc "Validated uplink configuration with redacted inspection."

  import Bitwise

  @input_keys %{
    "interface" => :interface,
    "kind" => :kind,
    "method" => :method,
    "address" => :address,
    "prefix_length" => :prefix_length,
    "subnet_mask" => :subnet_mask,
    "gateway" => :gateway,
    "dns_primary" => :dns_primary,
    "dns_secondary" => :dns_secondary,
    "search_domain" => :search_domain,
    "ssid" => :ssid,
    "password" => :password,
    "hidden" => :hidden,
    "security" => :security
  }

  @enforce_keys [:interface, :kind, :method]
  defstruct [
    :interface,
    :kind,
    :method,
    :address,
    :prefix_length,
    :gateway,
    :dns_primary,
    :dns_secondary,
    :search_domain,
    :ssid,
    :password,
    hidden: false,
    security: :wpa_psk
  ]

  @type t :: %__MODULE__{
          interface: String.t(),
          kind: :ethernet | :wifi,
          method: :dhcp | :static,
          address: String.t() | nil,
          prefix_length: 0..32 | nil,
          gateway: String.t() | nil,
          dns_primary: String.t() | nil,
          dns_secondary: String.t() | nil,
          search_domain: String.t() | nil,
          ssid: String.t() | nil,
          password: String.t() | nil,
          hidden: boolean(),
          security: :open | :wpa_psk
        }

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(params) when is_map(params) do
    config = %__MODULE__{
      interface: value(params, "interface"),
      kind: kind(value(params, "kind")),
      method: method(value(params, "method")),
      address: blank_nil(value(params, "address")),
      prefix_length: prefix(value(params, "prefix_length") || value(params, "subnet_mask")),
      gateway: blank_nil(value(params, "gateway")),
      dns_primary: blank_nil(value(params, "dns_primary")),
      dns_secondary: blank_nil(value(params, "dns_secondary")),
      search_domain: blank_nil(value(params, "search_domain")),
      ssid: blank_nil(value(params, "ssid")),
      password: blank_nil(value(params, "password")),
      hidden: truthy?(value(params, "hidden")),
      security: security(value(params, "security"))
    }

    case errors(config) do
      errors when map_size(errors) == 0 -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  def new(_params), do: {:error, %{configuration: "must be an object"}}

  @spec from_persisted(map()) :: {:ok, t()} | {:error, term()}
  def from_persisted(%{"version" => 1} = persisted), do: new(persisted)
  def from_persisted(_persisted), do: {:error, :unsupported_network_configuration}

  @spec to_persisted(t()) :: map()
  def to_persisted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode_value(value)} end)
    |> Map.put("version", 1)
  end

  @spec to_public(t() | nil) :: map() | nil
  def to_public(nil), do: nil

  def to_public(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:password])
    |> Map.put(:credentials_configured, is_binary(config.password))
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(config, opts) do
      public = NervesGate.Internet.Config.to_public(config)
      concat(["#NervesGate.Internet.Config<", to_doc(public, opts), ">"])
    end
  end

  defp errors(config) do
    %{}
    |> required(:interface, config.interface, &valid_interface?/1)
    |> enum(:kind, config.kind, [:ethernet, :wifi])
    |> enum(:method, config.method, [:dhcp, :static])
    |> validate_static(config)
    |> validate_wifi(config)
  end

  defp validate_static(errors, %{method: :dhcp}), do: errors

  defp validate_static(errors, config) do
    errors
    |> required(:address, config.address, &ipv4?/1)
    |> required(:prefix_length, config.prefix_length, &is_integer/1)
    |> required(:gateway, config.gateway, &ipv4?/1)
    |> required(:dns_primary, config.dns_primary, &ipv4?/1)
    |> optional_ip(:dns_secondary, config.dns_secondary)
    |> optional_domain(:search_domain, config.search_domain)
  end

  defp validate_wifi(errors, %{kind: :ethernet}), do: errors

  defp validate_wifi(errors, config) do
    errors
    |> required(:ssid, config.ssid, &(is_binary(&1) and byte_size(&1) in 1..32))
    |> enum(:security, config.security, [:open, :wpa_psk])
    |> validate_password(config)
  end

  defp validate_password(errors, %{security: :open}), do: errors

  defp validate_password(errors, config) do
    required(errors, :password, config.password, &(is_binary(&1) and byte_size(&1) in 8..63))
  end

  defp required(errors, field, value, validator) do
    if validator.(value), do: errors, else: Map.put(errors, field, "is invalid or missing")
  end

  defp enum(errors, field, value, accepted) do
    if value in accepted, do: errors, else: Map.put(errors, field, "is invalid")
  end

  defp optional_ip(errors, _field, nil), do: errors
  defp optional_ip(errors, field, value), do: required(errors, field, value, &ipv4?/1)

  defp optional_domain(errors, _field, nil), do: errors

  defp optional_domain(errors, field, value) do
    valid? = is_binary(value) and String.match?(value, ~r/^[A-Za-z0-9.-]+$/)
    if valid?, do: errors, else: Map.put(errors, field, "is invalid")
  end

  defp valid_interface?(value),
    do: is_binary(value) and String.match?(value, ~r/^[a-zA-Z0-9_.-]{1,15}$/)

  defp ipv4?(value) when is_binary(value) do
    match?({:ok, {_a, _b, _c, _d}}, :inet.parse_ipv4_address(String.to_charlist(value)))
  end

  defp ipv4?(_value), do: false

  defp prefix(value) when is_integer(value) and value in 0..32, do: value

  defp prefix(value) when is_binary(value) do
    case Integer.parse(value) do
      {prefix, ""} when prefix in 0..32 -> prefix
      _other -> mask_to_prefix(value)
    end
  end

  defp prefix(_value), do: nil

  defp mask_to_prefix(mask) do
    with {:ok, {a, b, c, d}} <- :inet.parse_ipv4_address(String.to_charlist(mask)),
         bits = (a <<< 24) + (b <<< 16) + (c <<< 8) + d,
         binary = Integer.to_string(bits, 2) |> String.pad_leading(32, "0"),
         true <- String.match?(binary, ~r/^1*0*$/) do
      binary |> String.split("0", parts: 2) |> hd() |> String.length()
    else
      _other -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Map.fetch!(@input_keys, key))

  defp kind(value) when value in [:ethernet, "ethernet"], do: :ethernet
  defp kind(value) when value in [:wifi, "wifi"], do: :wifi
  defp kind(_value), do: nil

  defp method(value) when value in [:dhcp, "dhcp"], do: :dhcp
  defp method(value) when value in [:static, "static"], do: :static
  defp method(_value), do: nil

  defp security(value) when value in [:open, "open"], do: :open
  defp security(value) when value in [:wpa_psk, "wpa_psk", "wpa2"], do: :wpa_psk
  defp security(_value), do: :wpa_psk

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value) when is_binary(value), do: String.trim(value)
  defp blank_nil(value), do: value
  defp encode_value(nil), do: nil
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
end

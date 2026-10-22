defmodule NervesGate.Network.Cellular do
  @moduledoc """
  Firmware-supplied modem identity and VintageNet configuration, not a modem manager.

  `:nerves_gate, :cellular` is nil on platforms without a modem profile. A profile
  contains `:interface` and a standard VintageNet `:config` (ECM, QMI or Mobile).
  EC100 uses the Quectel EG800AK's ECM data path. Power/reset and stable interface
  naming belong to the BSP. Never use the recovery gadget's usb0.
  """
  alias NervesGate.Config

  def profile do
    case Application.get_env(:nerves_gate, :cellular) do
      %{interface: name, config: %{type: type} = config} = profile
      when is_binary(name) and is_atom(type) ->
        if Regex.match?(~r/\A(?:wwan|ppp|cell)[0-9]+\z/, name) and
             technology_key(config) != nil and Code.ensure_loaded?(type),
           do: profile

      _ ->
        nil
    end
  end

  def configurations(network) do
    case {profile(), Config.cellular?(network)} do
      {nil, true} ->
        {:error, :cellular_unsupported}

      {nil, false} ->
        {:ok, []}

      {%{interface: name}, false} ->
        {:ok, [{name, %{type: VintageNet.Technology.Null}}]}

      {%{interface: name, config: config}, true} ->
        key = technology_key(config)

        options =
          Map.put(config[key], :service_providers, [%{apn: Config.internet(network)["apn"]}])

        {:ok, [{name, Map.put(config, key, options)}]}
    end
  end

  defp technology_key(%{vintage_net_ecm: options}) when is_map(options), do: :vintage_net_ecm
  defp technology_key(%{vintage_net_qmi: options}) when is_map(options), do: :vintage_net_qmi

  defp technology_key(%{vintage_net_mobile: options}) when is_map(options),
    do: :vintage_net_mobile

  defp technology_key(_), do: nil
end

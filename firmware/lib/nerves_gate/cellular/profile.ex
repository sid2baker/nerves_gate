defmodule NervesGate.Cellular.Profile do
  @moduledoc "Board-selected modem wiring and VintageNet configurations."
  alias NervesGate.Config

  def get do
    case NervesGate.Board.get(:cellular) do
      %{interface: name, config: %{type: type} = config} = profile
      when is_binary(name) and is_atom(type) ->
        if Regex.match?(~r"\A(?:wwan|ppp|cell)[0-9]+\z", name) and technology_key(config) != nil and
             Code.ensure_loaded?(type) do
          profile
        end

      _ ->
        nil
    end
  end

  def configurations(network) do
    case {get(), Config.cellular?(network)} do
      {nil, true} ->
        {:error,
         %{
           code: "cellular_unsupported",
           message:
             "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
         }}

      {nil, false} ->
        {:ok, []}

      {%{
         interface: name,
         config:
           %{type: VintageNetECM, vintage_net_ecm: %{modem: NervesGate.Cellular.Modem}} = config
       }, false} ->
        options =
          Map.merge(config.vintage_net_ecm, %{setup_only: true, service_providers: [%{apn: ""}]})

        {:ok,
         [
           {name,
            config |> Map.put(:vintage_net_ecm, options) |> Map.put(:ipv4, %{method: :disabled})}
         ]}

      {%{interface: name}, false} ->
        {:ok, [{name, %{type: VintageNet.Technology.Null}}]}

      {%{interface: name, config: config}, true} ->
        key = technology_key(config)

        options =
          Map.put(config[key], :service_providers, [
            %{apn: Config.internet(network)["apn"]}
          ])

        options =
          if Config.internet(network)["provider"],
            do: Map.put(options, :carrier_profile, Config.internet(network)["provider"]),
            else: options

        {:ok, [{name, Map.put(config, key, options)}]}
    end
  end

  defp technology_key(%{vintage_net_ecm: options}) when is_map(options), do: :vintage_net_ecm

  defp technology_key(%{vintage_net_qmi: options}) when is_map(options), do: :vintage_net_qmi

  defp technology_key(%{vintage_net_mobile: options}) when is_map(options),
    do: :vintage_net_mobile

  defp technology_key(_), do: nil
end

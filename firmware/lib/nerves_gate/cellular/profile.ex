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

      {%{interface: name}, false} ->
        {:ok, [{name, %{type: VintageNet.Technology.Null}}]}

      {%{interface: name, config: config}, true} ->
        key = technology_key(config)

        options =
          Map.put(config[key], :service_providers, [
            %{apn: Config.internet(network)["apn"]}
          ])

        {:ok, [{name, Map.put(config, key, options)}]}
    end
  end

  @doc false
  def check_saved(%{type: VintageNet.Technology.Null}), do: :ok

  def check_saved(%{type: VintageNetECM, vintage_net_ecm: options}) when is_map(options) do
    modem = Map.get(options, :modem, VintageNetECM.Modem.Quectel)

    if is_atom(modem) and Code.ensure_loaded?(modem) and
         Enum.all?(VintageNetECM.Modem.behaviour_info(:callbacks), fn {name, arity} ->
           function_exported?(modem, name, arity)
         end),
       do: :ok,
       else: {:error, saved_error()}
  end

  def check_saved(_), do: {:error, saved_error()}

  defp saved_error do
    %{
      code: "cellular_saved_config_unavailable",
      message:
        "Saved cellular configuration is unsupported by this firmware. Startup stopped before opening the modem. Use an explicitly authorized reprovisioning procedure; settings were not changed."
    }
  end

  defp technology_key(%{vintage_net_ecm: options}) when is_map(options), do: :vintage_net_ecm

  defp technology_key(%{vintage_net_qmi: options}) when is_map(options), do: :vintage_net_qmi

  defp technology_key(%{vintage_net_mobile: options}) when is_map(options),
    do: :vintage_net_mobile

  defp technology_key(_), do: nil
end

defmodule NervesGate.Device.RemotePolicy do
  @moduledoc false
  alias NervesGate.{Remote, Device.Error, Device.NetworkPolicy}

  @commands %{
    "remote.connect" => :connect,
    "remote.configure" => :configure,
    "remote.disconnect" => :disconnect,
    "remote.login_url" => :login_url
  }

  def prepare(%{remote: remote, actions: actions} = input) do
    remote = remote || Remote.unavailable()

    reason =
      cond do
        not remote.available ->
          Error.new("remote_unavailable", "Tailscale is starting or unavailable.")

        remote.operation != nil ->
          Error.new("remote_busy", "A Tailscale change is still running.")

        true ->
          nil
      end

    additions =
      Map.new(@commands, fn {name, action} ->
        {name,
         %{
           label: label(action),
           required: if(action in [:connect, :configure], do: ["hostname"], else: []),
           enabled: is_nil(reason),
           reason: reason
         }}
      end)

    %{input | remote: remote, actions: Map.merge(actions, additions)}
  end

  def decide(%{command: %{action: name, params: params}, actions: actions} = context) do
    case Map.fetch(@commands, name) do
      {:ok, action} ->
        case actions[name] do
          %{enabled: false, reason: reason} ->
            {:error, reason}

          _ ->
            case Remote.validate(action, params) do
              {:ok, _} -> {:effect, {:remote, action, params}}
              {:error, error} -> {:error, error}
            end
        end

      :error ->
        NetworkPolicy.decide(context)
    end
  end

  defp label(:connect), do: "Connect Tailscale"
  defp label(:configure), do: "Save device name"
  defp label(:disconnect), do: "Disconnect Tailscale"
  defp label(:login_url), do: "Continue Tailscale login"
end

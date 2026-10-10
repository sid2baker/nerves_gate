defmodule NervesGate.Device.NetworkPolicy do
  @moduledoc false
  alias NervesGate.Config
  alias NervesGate.Device.Error

  # Shared by the projection branch and command branch of the workflow.
  def prepare(%{status: status} = input) do
    Map.put(input, :actions, %{
      "network.validate" => action("Review settings", ["network"], nil),
      "network.propose" => action("Try settings", ["network"], propose_reason(status)),
      "network.confirm" => action("Keep settings", ["trial_id"], confirm_reason(status)),
      "network.cancel" => action("Restore saved settings", ["trial_id"], trial_reason(status))
    })
  end

  def decide(%{command: %{action: name, params: params}, actions: actions, status: status}) do
    case Map.get(actions, name) do
      nil -> {:error, Error.new("unknown_action", "Unknown device action.")}
      %{enabled: false, reason: reason} -> {:error, reason}
      %{enabled: true} -> validate(name, params, status)
    end
  end

  defp validate(name, %{"network" => network} = params, _)
       when name in ["network.validate", "network.propose"] and map_size(params) == 1 do
    case Config.validate_network(network) do
      {:ok, network} when name == "network.validate" -> {:result, %{network: network}}
      {:ok, network} -> {:effect, {:propose, network}}
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  defp validate(name, %{"trial_id" => id} = params, %{trial: %{id: current}})
       when name in ["network.confirm", "network.cancel"] and is_binary(id) and
              map_size(params) == 1 do
    if id == current do
      effect = if name == "network.confirm", do: :confirm, else: :cancel
      {:effect, {effect, id}}
    else
      {:error, Error.from(:no_matching_trial)}
    end
  end

  defp validate(_, _, _),
    do:
      {:error,
       Error.new("invalid_parameters", "Supply exactly the action's required parameters.")}

  defp action(label, required, reason) do
    %{
      label: label,
      required: required,
      enabled: is_nil(reason),
      reason: reason && Error.from(reason)
    }
  end

  defp propose_reason(nil), do: :unavailable
  defp propose_reason(%{config: nil}), do: :invalid_saved_config
  defp propose_reason(%{trial: trial}) when not is_nil(trial), do: :trial_in_progress
  defp propose_reason(%{recovering: true}), do: :recovery_in_progress
  defp propose_reason(_), do: nil

  defp trial_reason(nil), do: :unavailable
  defp trial_reason(%{trial: nil}), do: :no_matching_trial
  defp trial_reason(_), do: nil

  defp confirm_reason(status) do
    trial_reason(status) || if(status.ready, do: nil, else: :not_connected)
  end
end

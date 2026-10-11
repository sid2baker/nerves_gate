defmodule NervesGate.Device.Actions do
  @moduledoc """
  The complete device action catalog and pure command router.

  Clients call `NervesGate.Device.dispatch/3`, not this module. `prepare/1`
  supplies the same action availability to the UI and to `decide/1`.
  Decisions describe effects; only Device executes them through Network or Remote.
  """
  alias NervesGate.Config
  alias NervesGate.Device.Error
  alias NervesGate.Remote

  @catalog %{
    "network.validate" => {"Review settings", ["network"]},
    "network.propose" => {"Try settings", ["network"]},
    "network.confirm" => {"Keep settings", ["trial_id"]},
    "network.cancel" => {"Restore saved settings", ["trial_id"]},
    "remote.connect" => {"Connect Tailscale", ["hostname"]},
    "remote.configure" => {"Save device name", ["hostname"]},
    "remote.disconnect" => {"Disconnect Tailscale", []},
    "remote.login_url" => {"Continue Tailscale login", []}
  }
  def prepare(%{status: status, remote: remote} = input) do
    remote = remote || Remote.unavailable()

    actions =
      Map.new(@catalog, fn {id, {label, required}} ->
        reason = reason(id, status, remote)
        {id, %{label: label, required: required, enabled: is_nil(reason), reason: reason}}
      end)

    input |> Map.put(:remote, remote) |> Map.put(:actions, actions)
  end

  def decide(%{command: %{action: id, params: params}, actions: actions, status: status}) do
    case Map.get(actions, id) do
      nil -> {:error, Error.new("unknown_action", "Unknown device action.")}
      %{enabled: false, reason: reason} -> {:error, reason}
      %{enabled: true} -> route(id, params, status)
    end
  end

  # Every public action has an explicit destination; there is no dynamic module dispatch.
  defp route("network.validate", params, _) do
    network(:validate, params)
  end

  defp route("network.propose", params, _) do
    network(:propose, params)
  end

  defp route("network.confirm", params, status) do
    trial(:confirm, params, status)
  end

  defp route("network.cancel", params, status) do
    trial(:cancel, params, status)
  end

  defp route("remote.connect", params, _) do
    remote(:connect, params)
  end

  defp route("remote.configure", params, _) do
    remote(:configure, params)
  end

  defp route("remote.disconnect", params, _) do
    remote(:disconnect, params)
  end

  defp route("remote.login_url", params, _) do
    remote(:login_url, params)
  end

  defp network(action, %{"network" => network} = params) when map_size(params) == 1 do
    case Config.validate_network(network) do
      {:ok, network} -> network_result(action, network)
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  defp network(_, _) do
    invalid_parameters()
  end

  defp network_result(:validate, network), do: {:result, %{network: network}}
  defp network_result(:propose, network), do: {:effect, {:propose, network}}

  defp trial(action, %{"trial_id" => id} = params, %{trial: %{id: current}})
       when is_binary(id) and map_size(params) == 1 do
    if id == current do
      {:effect, {action, id}}
    else
      {:error, Error.from(:no_matching_trial)}
    end
  end

  defp trial(_, _, _) do
    invalid_parameters()
  end

  defp remote(action, params) do
    case Remote.validate(action, params) do
      {:ok, _} -> {:effect, {:remote, action, params}}
      {:error, error} -> {:error, error}
    end
  end

  defp invalid_parameters do
    {:error, Error.new("invalid_parameters", "Supply exactly the action's required parameters.")}
  end

  defp reason("network.validate", _, _) do
    nil
  end

  defp reason("network.propose", status, _) do
    error(propose_reason(status))
  end

  defp reason("network.confirm", status, _) do
    error(confirm_reason(status))
  end

  defp reason("network.cancel", status, _) do
    error(trial_reason(status))
  end

  defp reason(_, _, %{available: false}) do
    Error.new("remote_unavailable", "Tailscale is starting or unavailable.")
  end

  defp reason(_, _, %{operation: operation}) when not is_nil(operation) do
    Error.new("remote_busy", "A Tailscale change is still running.")
  end

  defp reason(_, _, _) do
    nil
  end

  defp error(nil) do
    nil
  end

  defp error(reason) do
    Error.from(reason)
  end

  defp propose_reason(nil) do
    :unavailable
  end

  defp propose_reason(%{config: nil}) do
    :invalid_saved_config
  end

  defp propose_reason(%{trial: trial}) when not is_nil(trial) do
    :trial_in_progress
  end

  defp propose_reason(%{recovering: true}) do
    :recovery_in_progress
  end

  defp propose_reason(_) do
    nil
  end

  defp trial_reason(nil) do
    :unavailable
  end

  defp trial_reason(%{trial: nil}) do
    :no_matching_trial
  end

  defp trial_reason(_) do
    nil
  end

  defp confirm_reason(status) do
    trial_reason(status) ||
      if status.ready do
        nil
      else
        :not_connected
      end
  end
end

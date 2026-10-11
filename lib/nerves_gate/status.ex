defmodule NervesGate.Status do
  @moduledoc "Pure status builder behind `NervesGate.status/1`. No process, cache or command execution."
  alias NervesGate.{Config, Network, Remote}
  alias NervesGate.Error
  alias NervesGate.Observations.Network, as: NetworkObservation

  def build(status, remote) do
    %{
      version: 2,
      system: %{firmware: NervesGate.version(), target: to_string(NervesGate.target())},
      network: network(status),
      connections: connections(status),
      capabilities: %{
        ethernet: true,
        mobile: false,
        failover: false,
        remote_enrollment: remote.available
      },
      remote_access: remote,
      actions: actions(status, remote)
    }
  end

  # Presentation metadata only. Admission belongs to the domain servers.
  defp actions(status, remote) do
    trial = if status && status.trial, do: :ok, else: {:error, :no_matching_trial}
    confirm = if trial == :ok and not status.ready, do: {:error, :not_connected}, else: trial
    remote_ready = Remote.Policy.available(remote)

    %{
      "network.validate" => action("Review settings", ["network"], :ok),
      "network.propose" => action("Try settings", ["network"], Network.Policy.available(status)),
      "network.confirm" => action("Keep settings", ["trial_id"], confirm),
      "network.cancel" => action("Restore saved settings", ["trial_id"], trial),
      "remote.connect" => action("Connect Tailscale", ["hostname"], remote_ready),
      "remote.configure" => action("Save device name", ["hostname"], remote_ready),
      "remote.disconnect" => action("Disconnect Tailscale", [], remote_ready),
      "remote.login_url" => action("Continue Tailscale login", [], remote_ready)
    }
  end

  defp action(label, required, result) do
    reason =
      case result do
        :ok -> nil
        {:error, reason} -> Error.from(reason)
      end

    %{label: label, required: required, enabled: reason == nil, reason: reason}
  end

  defp connections(status) do
    observed = status && status.observed
    settings = NetworkObservation.settings(status)
    ports = if observed, do: observed.ports, else: []
    internet = NetworkObservation.internet_interface(settings, observed)

    %{
      mode: settings && settings["mode"],
      suggested_internet_port: Network.Discovery.internet_port(ports),
      ports: Enum.map(ports, &Map.put(&1, :role, port_role(settings, &1.name))),
      internet: %{
        link: internet != nil and internet.link,
        addressed: internet != nil and Map.get(internet, :addresses, []) != [],
        health: if(NetworkObservation.internet(status).online, do: "online", else: "unverified"),
        backup: "unavailable"
      },
      problems: if(settings, do: Network.Policy.conflicts(observed, settings), else: [])
    }
  end

  defp port_role(%{"mode" => "shared"}, _), do: "shared"

  defp port_role(settings, name),
    do: get_in(Config.ports(settings), [name, "role"]) || "unassigned"

  defp network(nil) do
    %{
      available: false,
      desired: nil,
      pending: nil,
      observed: nil,
      defaults: Config.defaults()["network"],
      setup_completed: false,
      recovering: false,
      ready: false,
      error: Error.from(:unavailable)
    }
  end

  defp network(status) do
    %{
      available: true,
      desired: status.config && status.config["network"],
      pending: status.trial,
      observed: status.observed,
      defaults: Config.defaults()["network"],
      setup_completed: status.config != nil and status.config["setup_completed"],
      recovering: status.recovering,
      ready: status.ready,
      error: status.error
    }
  end
end

defmodule NervesGate.Device.Projection do
  @moduledoc false
  alias NervesGate.Config
  alias NervesGate.Device.Error

  def build(%{status: status, actions: actions}) do
    %{
      version: 2,
      system: %{firmware: NervesGate.version(), target: to_string(NervesGate.target())},
      network: network(status),
      connections: connections(status),
      capabilities: %{ethernet: true, mobile: false, failover: false, remote_enrollment: false},
      remote_access: %{state: "unavailable", verified: false, permitted_routes: nil},
      actions: actions
    }
  end

  defp connections(status) do
    observed = status && status.observed

    settings =
      status &&
        ((status.trial && status.trial.network) || (status.config && status.config["network"]))

    mode = settings && settings["mode"]
    ports = if observed, do: observed.ports, else: []

    internet =
      cond do
        !observed -> nil
        mode == "ethernet" -> Enum.find(ports, &(&1.name == settings["internet_port"]))
        mode == "shared" -> observed.bridge
        true -> nil
      end

    %{
      mode: mode,
      ports:
        Enum.map(ports, fn port ->
          role =
            cond do
              mode == "shared" -> "shared"
              mode != "ethernet" -> "unassigned"
              port.name == settings["internet_port"] -> "internet"
              true -> "equipment"
            end

          Map.put(port, :role, role)
        end),
      internet: %{
        link: internet != nil and internet.link,
        addressed: internet != nil and Map.get(internet, :addresses, []) != [],
        health:
          if(internet && Map.get(internet, :connection) == :internet,
            do: "online",
            else: "unverified"
          ),
        backup: "unavailable"
      },
      problems: if(settings, do: NervesGate.Network.conflicts(observed, settings), else: [])
    }
  end

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

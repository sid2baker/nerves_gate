defmodule NervesGate.Device.Projection do
  @moduledoc false
  alias NervesGate.Config
  alias NervesGate.Device.Error

  def build(%{status: status, actions: actions, remote: remote}) do
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

    suggested = NervesGate.Network.Discovery.internet_port(ports)

    internet_port =
      if mode == "unconfigured", do: suggested, else: Config.role_port(settings, "internet")

    internet =
      if mode == "shared" and observed,
        do: observed.bridge,
        else: Enum.find(ports, &(&1.name == internet_port))

    %{
      mode: mode,
      suggested_internet_port: suggested,
      ports:
        Enum.map(ports, fn port ->
          role =
            cond do
              mode == "shared" -> "shared"
              true -> get_in(Config.ports(settings), [port.name, "role"]) || "unassigned"
            end

          Map.put(port, :role, role)
        end),
      internet: %{
        link: internet != nil and internet.link,
        addressed: internet != nil and Map.get(internet, :addresses, []) != [],
        health:
          if(
            internet && internet.link && Map.get(internet, :addresses, []) != [] &&
              Map.get(internet, :connection) == :internet,
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

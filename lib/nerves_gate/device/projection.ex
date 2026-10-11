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
    settings = connection_settings(status)
    mode = settings && settings["mode"]

    ports =
      if observed do
        observed.ports
      else
        []
      end

    suggested = NervesGate.Network.Discovery.internet_port(ports)

    internet_port =
      if mode == "unconfigured" do
        suggested
      else
        Config.role_port(settings, "internet")
      end

    internet = internet_interface(mode, observed, ports, internet_port)

    %{
      mode: mode,
      suggested_internet_port: suggested,
      ports: Enum.map(ports, &Map.put(&1, :role, port_role(settings, &1.name))),
      internet: internet_status(internet),
      problems:
        if settings do
          NervesGate.Network.conflicts(observed, settings)
        else
          []
        end
    }
  end

  defp connection_settings(nil) do
    nil
  end

  defp connection_settings(%{trial: %{network: network}}) do
    network
  end

  defp connection_settings(%{config: config}) do
    config && config["network"]
  end

  defp internet_interface("shared", observed, _, _) do
    observed && observed.bridge
  end

  defp internet_interface(_, _, ports, name) do
    Enum.find(ports, &(&1.name == name))
  end

  defp port_role(%{"mode" => "shared"}, _) do
    "shared"
  end

  defp port_role(settings, name) do
    get_in(Config.ports(settings), [name, "role"]) || "unassigned"
  end

  defp internet_status(nil) do
    %{link: false, addressed: false, health: "unverified", backup: "unavailable"}
  end

  defp internet_status(internet) do
    addressed = Map.get(internet, :addresses, []) != []
    online = internet.link and addressed and Map.get(internet, :connection) == :internet

    %{
      link: internet.link,
      addressed: addressed,
      health:
        if online do
          "online"
        else
          "unverified"
        end,
      backup: "unavailable"
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

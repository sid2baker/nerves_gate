defmodule NervesGate.Status do
  @moduledoc "Pure status builder behind `NervesGate.status/1`. No process, cache or command execution."
  alias NervesGate.{Buses, Config, Equipment, Indicators, Network, Remote}
  alias NervesGate.Equipment.Subnet
  alias NervesGate.Error
  alias NervesGate.Network.Cellular
  alias NervesGate.Observations.Network, as: NetworkObservation
  alias NervesGate.Remote.Sharing

  def build(
        status,
        remote,
        equipment,
        indicators,
        buses,
        ssh,
        system,
        storage \\ NervesGate.Storage.unavailable()
      ) do
    cellular = cellular_supported?(status)

    %{
      version: 7,
      system: system,
      backend: %{available: true, error: nil},
      network: network(status),
      connections: connections(status),
      cellular: Cellular.view(status),
      capabilities: %{
        ethernet: true,
        mobile: cellular,
        failover: cellular,
        remote_enrollment: remote.available
      },
      remote_access: remote,
      sharing: sharing(status, remote),
      equipment: equipment(status, equipment),
      indicators: indicators,
      buses: buses,
      ssh: ssh,
      storage: storage,
      actions: actions(status, remote, equipment, indicators, buses, ssh)
    }
  end

  @doc "An empty view, not a cached or simulated device snapshot."
  def disconnected do
    error = Error.new("backend_disconnected", "The device is disconnected or not responding.")
    system = %{firmware: "—", target: "—", node: :nonode@nohost, elixir: "—", otp: "—"}

    status =
      build(
        nil,
        Remote.unavailable(),
        Equipment.unavailable(),
        Indicators.unavailable(),
        Buses.unavailable(),
        NervesGate.SSH.unavailable(),
        system
      )

    %{
      status
      | backend: %{available: false, error: error},
        actions:
          Map.new(status.actions, fn {name, action} ->
            {name, %{action | enabled: false, reason: error}}
          end)
    }
  end

  defp cellular_supported?(%{observed: observed}) when is_map(observed),
    do: Map.get(observed, :cellular_supported, false)

  defp cellular_supported?(_), do: false

  # Presentation metadata only. Admission belongs to the domain servers.
  defp actions(status, remote, equipment, indicators, buses, ssh) do
    trial = if status && status.trial, do: :ok, else: {:error, :no_matching_trial}
    confirm = if trial == :ok and not status.ready, do: {:error, :not_connected}, else: trial
    remote_ready = Remote.Policy.available(remote)
    ssh_ready = ssh_available(ssh)

    %{
      "network.validate" => action("Review settings", ["network"], :ok),
      "network.propose" => action("Try settings", ["network"], lan_available(status)),
      "network.confirm" => action("Keep settings", ["trial_id"], confirm),
      "network.cancel" => action("Restore saved settings", ["trial_id"], trial),
      "cellular.refresh" => action("Refresh cellular status", [], cellular_available(status)),
      "cellular.unlock" =>
        action("Unlock SIM", ["pin"], cellular_available(status, :pin_required)),
      "cellular.change_pin" =>
        action("Change SIM PIN", ["current_pin", "new_pin"], cellular_available(status, :ready)),
      "cellular.set_pin_lock" =>
        action("Set SIM PIN protection", ["enabled", "pin"], cellular_available(status, :ready)),
      "cellular.save_pin" =>
        action("Verify and save SIM PIN", ["pin"], cellular_available(status, :ready)),
      "cellular.forget_pin" => action("Forget saved PIN", [], cellular_forget_available(status)),
      "remote.connect" => action("Connect Tailscale", ["hostname"], remote_ready),
      "remote.configure" => action("Save device name", ["hostname"], remote_ready),
      "remote.disconnect" => action("Disconnect Tailscale", [], remote_ready),
      "remote.login_url" => action("Continue Tailscale login", [], remote_ready),
      "equipment.scan" => action("Scan equipment subnet", [], scan_available(status, equipment)),
      "equipment.label" => action("Save label", ["id", "label"], labels_available(equipment)),
      "equipment.share" =>
        action(
          "Share equipment",
          [],
          sharing_available(status, remote)
        ),
      "equipment.unshare" => action("Turn sharing off", [], unshare_available(status, remote)),
      "bus.configure" =>
        action("Configure bus", ["port", "enabled"], Buses.Policy.available(buses)),
      "bus.capture" => action("Capture bus", ["port"], Buses.Policy.available(buses)),
      "bus.modbus_read" =>
        action(
          "Read Modbus registers",
          ["port", "unit", "function", "address", "count", "authorized"],
          Buses.Policy.available(buses)
        ),
      "ssh.add_key" => action("Add SSH key", ["public_key"], ssh_ready),
      "ssh.remove_key" => action("Remove SSH key", ["fingerprint"], ssh_ready),
      "identify" => action("Identify gateway", [], identify_available(indicators))
    }
  end

  defp cellular_available(nil), do: {:error, :unavailable}
  defp cellular_available(status), do: Cellular.available(status)

  defp cellular_forget_available(nil), do: {:error, :unavailable}
  defp cellular_forget_available(status), do: Cellular.available(status, :forget_pin)

  defp cellular_available(status, sim) do
    with :ok <- cellular_available(status) do
      if Cellular.view(status).sim == sim, do: :ok, else: {:error, :cellular_sim_changed}
    end
  end

  defp ssh_available(%{available: true}), do: :ok
  defp ssh_available(_), do: {:error, :ssh_keys_unavailable}

  defp identify_available(%{recovery: %{action: action}}) when not is_nil(action),
    do: {:error, :operation_in_progress}

  defp identify_available(%{led: %{identifying: true}}), do: {:error, :operation_in_progress}
  defp identify_available(%{led: %{restore_pending: true}}), do: {:error, :led_restore_failed}
  defp identify_available(%{led: %{available: true}}), do: :ok
  defp identify_available(_), do: {:error, :led_unavailable}

  defp sharing(status, remote) do
    subnet =
      case Sharing.scope(status) do
        {:ok, scope} -> scope.cidr
        _ -> nil
      end

    enabled =
      if remote.available and Sharing.known(remote) == :ok and is_list(remote.advertised_routes) do
        subnet != nil and subnet in remote.advertised_routes
      end

    %{
      subnet: subnet,
      enabled: enabled,
      other_routes: Enum.reject(remote.advertised_routes || [], &(&1 == subnet))
    }
  end

  defp lan_available(status) do
    with :ok <- Network.Policy.available(status),
         do: Map.get(status, :sharing_admission, :ok)
  end

  defp sharing_available(status, remote) do
    with :ok <- Network.Policy.available(status),
         {:ok, _} <- Sharing.enable(status, remote),
         do: :ok
  end

  defp unshare_available(status, remote) do
    with :ok <- Network.Policy.available(status),
         {:ok, _} <- Sharing.disable(status, remote),
         do: :ok
  end

  defp equipment(status, equipment) do
    scope =
      case Subnet.from_status(status) do
        {:ok, scope} -> scope
        _ -> nil
      end

    if equipment.scope == scope and scope != nil do
      equipment
    else
      %{equipment | scope: scope, entries: [], last_scan: nil, operation: nil, error: nil}
    end
  end

  defp scan_available(_, %{available: false}) do
    {:error, :equipment_unavailable}
  end

  defp scan_available(status, _) do
    with :ok <- Network.Policy.available(status), {:ok, _} <- Subnet.active(status) do
      :ok
    end
  end

  defp labels_available(%{available: false}) do
    {:error, :equipment_unavailable}
  end

  defp labels_available(%{labels_error: nil}) do
    :ok
  end

  defp labels_available(_) do
    {:error, :labels_unavailable}
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
    uplinks = NetworkObservation.internet(status)

    %{
      mode: settings && settings["mode"],
      suggested_internet_port: Network.Discovery.internet_port(ports),
      ports: Enum.map(ports, &Map.put(&1, :role, port_role(settings, &1.name))),
      cellular: observed && Map.get(observed, :cellular),
      internet: internet_connection(internet, uplinks),
      problems: if(settings, do: Network.Policy.conflicts(observed, settings), else: [])
    }
  end

  defp internet_connection(internet, uplinks) do
    %{
      mode: uplinks.mode,
      selected: uplinks.selected,
      ethernet: uplinks.ethernet,
      cellular: uplinks.cellular,
      link: internet != nil and internet.link,
      addressed: internet != nil and Map.get(internet, :addresses, []) != [],
      health: if(uplinks.online, do: "online", else: "unverified"),
      backup: if(uplinks.backup, do: "active", else: to_string(uplinks.cellular))
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

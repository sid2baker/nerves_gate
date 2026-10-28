defmodule NervesGate.Network.Policy do
  @moduledoc "Pure trial admission, topology readiness and observed subnet conflict checks."
  alias NervesGate.Config

  def assignable(status, interface) do
    network = status.config && status.config["network"]
    ports = Config.ports(network)
    observed = status.observed || %{ports: []}

    if interface in ["eth0", "eth1"] and network["mode"] == "ports" and
         get_in(ports, [interface, "role"]) != "internet" and
         Enum.any?(observed.ports, &(&1.name == interface and &1.present and &1.master == nil)),
       do: :ok,
       else:
         {:error,
          NervesGate.Error.new(
            "hardware_reserved",
            "Internet, joined, missing and management interfaces cannot be assigned."
          )}
  end

  def hardware_change(network, assignments) do
    assigned =
      for {name, setting} <- assignments,
          name in ["eth0", "eth1"] and (setting.enabled or setting.plugin != nil),
          do: name

    conflict =
      (network["mode"] != "ports" and assigned != []) or
        Enum.any?(assigned, &(get_in(network, [&1, "role"]) == "internet"))

    if conflict,
      do:
        {:error,
         NervesGate.Error.new(
           "hardware_assigned",
           "Disable and unassign this LAN under Hardware before using it for Internet."
         )},
      else: :ok
  end

  def available(nil),
    do:
      {:error,
       %{
         code: "unavailable",
         message: "Network control is unavailable. Reconnect and read the current state."
       }}

  def available(%{config: nil}),
    do:
      {:error,
       %{
         code: "invalid_saved_config",
         message:
           "Saved settings could not be used. Inspect them with recovery SSH or serial; an explicitly authorized change is required. No saved settings were rewritten."
       }}

  def available(%{recovering: true}),
    do:
      {:error,
       %{
         code: "recovery_in_progress",
         message: "Wait for saved settings to be restored before trying again."
       }}

  def available(%{trial: trial}) when not is_nil(trial),
    do: {:error, %{code: "trial_in_progress", message: "Another client already started a trial."}}

  def available(%{phase: phase}) when phase not in [:idle, :pending] do
    {:error,
     %{code: "operation_in_progress", message: "Wait for the current operation to finish."}}
  end

  def available(%{local: local}) when not is_nil(local), do: NervesGate.Network.Local.idle(local)

  def available(_) do
    :ok
  end

  @doc false
  def trial_available(%{trial: trial, ready: ready}, operation) when not is_nil(trial) do
    if operation == :confirm and not ready,
      do:
        {:error,
         %{
           code: "not_connected",
           message:
             "Port settings are not ready to save. Check the connection status and any address conflicts below."
         }},
      else: :ok
  end

  def trial_available(_, _), do: matching(nil, nil)

  def matching(%{trial: %{id: id}}, id), do: :ok

  def matching(_, _),
    do:
      {:error,
       %{code: "no_matching_trial", message: "This trial has ended. Review your settings again."}}

  def supported(observed, network, current \\ nil) do
    cond do
      not Config.cellular?(network) ->
        :ok

      not match?(%{cellular_supported: true}, observed) ->
        {:error,
         %{
           code: "cellular_unsupported",
           message:
             "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
         }}

      Config.internet(network) == Config.internet(current) ->
        :ok

      not match?(%{cellular: %{present: true}}, observed) ->
        {:error,
         %{
           code: "cellular_missing",
           message:
             "The configured cellular interface is not detected. Check modem power and USB enumeration."
         }}

      true ->
        :ok
    end
  end

  defp cellular_ready?(observed, network) do
    not Config.cellular?(network) or
      (match?(%{cellular: %{configured: true}}, observed) and
         observed.cellular.apn == Config.internet(network)["apn"])
  end

  @doc "Readiness is configured topology, NOT Internet access, a link or a DHCP lease."

  def ready?(%{ports: ports} = observed, %{"mode" => "ports"} = network) do
    Enum.all?(Config.ports(network), fn {name, setting} ->
      port_ready?(Enum.find(ports, &(&1.name == name)), setting)
    end) and cellular_ready?(observed, network) and conflicts(observed, network) == []
  end

  def ready?(_, _), do: false

  def conflicts(%{ports: ports} = observed, network) do
    networks = ports
    cellular = if Config.cellular?(network), do: List.wrap(Map.get(observed, :cellular)), else: []
    networks = networks ++ cellular
    usb = Map.get(observed, :usb, %{addresses: []})

    pairs =
      for {left, i} <- Enum.with_index(networks ++ [usb]),
          {right, j} <- Enum.with_index(networks ++ [usb]),
          i < j,
          a <- Map.get(left, :addresses, []),
          b <- Map.get(right, :addresses, []),
          Config.overlap?(a.address, a.prefix_length, b.address, b.prefix_length),
          do: {i, j}

    if pairs == [],
      do: [],
      else: [
        "Network addresses overlap. Use different Ethernet, cellular, plugin LAN and USB subnets before continuing."
      ]
  end

  def conflicts(_, _), do: []

  defp port_ready?(nil, setting), do: is_nil(setting)
  defp port_ready?(%{present: false}, setting), do: is_nil(setting)
  defp port_ready?(port, nil), do: configured_port?(port) and port.method == "disabled"

  defp port_ready?(port, %{"role" => "plugin", "address" => nil}),
    do:
      configured_port?(port) and port.method in ["disabled", "static"] and
        Map.get(port, :gateway) == nil and Map.get(port, :nameservers, []) == []

  defp port_ready?(port, %{"address" => address}) do
    configured_port?(port) and port.method == address["ip_method"] and
      (port.method == "dhcp" or address_matches?(port.addresses, address))
  end

  defp configured_port?(port), do: port.state == :configured and is_nil(port.master)

  defp address_matches?(addresses, network) do
    Enum.any?(addresses, fn %{address: address, prefix_length: prefix} ->
      case network["ip_method"] do
        "dhcp" ->
          match?({:ok, {a, _, _, _}} when a > 0 and a < 224 and a != 127, Config.ipv4(address))

        "static" ->
          address == network["static_ip"] and
            Config.prefix_length(network["subnet_mask"]) == {:ok, prefix}
      end
    end)
  end
end

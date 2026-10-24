defmodule Scenarios.Device do
  @moduledoc """
  Common scenario access to a running Nerves Gate node.

  A target is a map with `:node`, an optional diagnostics `:dir`, and an optional
  owned `fixture: {:qemu, handle}`. These helpers neither boot devices nor configure networking.
  Calls are bounded and never retried. Fixture controls are host-only and explicit.
  """

  import ExUnit.Assertions

  def rpc(device, module, function, args \\ [], timeout \\ 15_000)
      when is_integer(timeout) and timeout > 0 do
    if Process.get(:simulator_control_failed), do: exit(:simulator_control_failed)
    :erpc.call(device.node, module, function, args, timeout)
  catch
    :error, {:erpc, _} ->
      # A lost write reply is not a rejection. Stop the worker before it can
      # replay a command, clean up or replace disks with an unknown guest state.
      Process.put(:simulator_control_failed, true)
      exit(:simulator_control_failed)
  end

  # Do not log commands or results: some public calls return private values.

  def status(device) do
    status = :erpc.call(device.node, NervesGate, :status, [], 2_000)
    log(device, "snapshots.log", status)
    status
  catch
    :error, {:erpc, _} -> nil
  end

  def await(device, phase, predicate, timeout \\ 30_000) do
    if report = Process.get(:scenario_report), do: report.(phase)
    poll(device, phase, predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll(device, phase, predicate, deadline) do
    status = status(device)

    cond do
      status && predicate.(status) ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Timed out: #{phase}; diagnostics: #{Map.get(device, :dir, "not configured")}")

      true ->
        Process.sleep(500)
        poll(device, phase, predicate, deadline)
    end
  end

  def fixture_capabilities(%{fixture: {:qemu, %{owner: owner} = handle}}) when is_pid(owner),
    do: Scenarios.Qemu.capabilities(handle)

  def fixture_capabilities(_), do: []

  def control(device, operation, args \\ []) do
    if operation in fixture_capabilities(device) do
      {:qemu, handle} = device.fixture
      Scenarios.Qemu.control(handle, operation, args)
    else
      {:error, :unsupported_fixture_control}
    end
  end

  @doc "Hardware resources declared by device domains, regardless of current presence."

  def resources(status) do
    for {resource, supported} <- [
          ethernet: status.connections.ports != [],
          cellular: status.cellular.supported,
          can: bus?(status.buses, "can"),
          rs485: bus?(status.buses, "rs485")
        ],
        supported,
        do: resource
  end

  @doc "Fail when required, declared hardware is missing; link/enabled state is separate."

  def assert_present(status, required) do
    ethernet = if :ethernet in required, do: status.connections.ports, else: []

    buses =
      Enum.filter(status.buses.ports, fn port ->
        Map.get(%{"can" => :can, "rs485" => :rs485}, port.transport) in required
      end)

    missing = for port <- ethernet ++ buses, port.present != true, do: port.name

    missing =
      if :cellular in required and status.cellular.present != true,
        do: ["cellular modem" | missing],
        else: missing

    assert missing == [], "Expected hardware missing or unobserved: #{Enum.join(missing, ", ")}"
    :ok
  end

  defp bus?(%{available: true, ports: ports}, transport),
    do: Enum.any?(ports, &(&1.transport == transport))

  defp bus?(_, _), do: false

  defp log(device, file, value) do
    if dir = device[:dir] do
      File.write!(
        Path.join(dir, file),
        "#{System.system_time(:millisecond)} #{inspect(value, limit: :infinity)}\n",
        [:append]
      )
    end
  end

  @behaviour :ssh_client_key_api

  def ssh_key do
    key = :public_key.generate_key({:namedCurve, :ed25519})
    public = :ssh_file.extract_public_key(key)
    line = :ssh_file.encode([{public, [comment: ~c"QEMU SSH scenario"]}], :auth_keys)
    {key, line, to_string(:ssh.hostkey_fingerprint(:sha256, public))}
  end

  def await_ssh(vm) do
    # Wait behind NervesSSH's host-key generation and daemon startup.
    assert {:ok, _info} =
             :erpc.call(vm.node, GenServer, :call, [NervesSSH, :info, 60_000], 65_000)
  end

  # StartupGuard validates the running slot, then removes its Heart callback. An
  # unknown status leaves the callback armed, rebooting after 15 minutes of uptime.
  def await_firmware_validated(vm) do
    Scenarios.Device.await(
      vm,
      "startup guard validated firmware",
      fn _ ->
        :erpc.call(vm.node, Nerves.Runtime, :firmware_validation_status, [], 2_000) ==
          :validated and :erpc.call(vm.node, :heart, :get_callback, [], 2_000) == :none
      end,
      150_000
    )
  end

  def ssh_public_key(vm, key) do
    Simulator.SSH.connect(vm, vm.forwards.ssh,
      user: ~c"root",
      key_cb: {__MODULE__, key: key},
      auth_methods: ~c"publickey",
      preferred_algorithms: [public_key: [:"ssh-ed25519"]]
    )
  end

  def user_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:key]}

  def user_key(_, _), do: {:error, :not_found}

  def is_host_key(_, _, _, _, _), do: true

  def add_host_key(_, _, _, _), do: :ok

  def settings(port) do
    Map.put(%{"mode" => "ports", "eth0" => nil, "eth1" => nil}, port, %{
      "role" => "internet",
      "address" => NervesGate.Config.address_defaults()
    })
  end

  def propose(vm, settings) do
    Scenarios.Device.await(vm, "configuration available", & &1.actions["network.propose"].enabled)
    assert {:ok, trial} = Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [settings])

    Scenarios.Device.await(
      vm,
      "configuration ready to save",
      & &1.actions["network.confirm"].enabled
    )

    trial
  end

  def save(vm, settings) do
    trial = propose(vm, settings)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])

    Scenarios.Device.await(
      vm,
      "settings saved",
      &(&1.network.setup_completed && &1.network.pending == nil && &1.network.desired == settings)
    )

    settings
  end

  def internet?(status) do
    addressed?(status) && status.connections.internet.health == "online" &&
      Enum.any?(status.connections.ports, &match?(%{name: "eth0", connection: :internet}, &1))
  end

  # A linked port with an IPv4 address, or without one when `addressed` is false.
  def addressed?(status, port \\ "eth0", addressed \\ true) do
    Enum.any?(status.connections.ports, fn
      %{name: ^port, link: true, addresses: [_ | _]} -> addressed
      %{name: ^port, link: true, addresses: []} -> not addressed
      _ -> false
    end)
  end
end

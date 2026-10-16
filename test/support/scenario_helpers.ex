defmodule NervesGate.ScenarioHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  @behaviour :ssh_client_key_api

  def ssh_key do
    key = :public_key.generate_key({:namedCurve, :ed25519})
    public = :ssh_file.extract_public_key(key)
    line = :ssh_file.encode([{public, [comment: ~c"QEMU SSH scenario"]}], :auth_keys)
    {key, line, to_string(:ssh.hostkey_fingerprint(:sha256, public))}
  end

  def await_ssh do
    # Wait behind NervesSSH's host-key generation and daemon startup.
    assert {:ok, _info} =
             :erpc.call(Qemu.guest(), GenServer, :call, [NervesSSH, :info, 60_000], 65_000)
  end

  def ssh_public_key(vm, key) do
    ssh_connect(vm.forwards.ssh,
      user: ~c"root",
      key_cb: {__MODULE__, key: key},
      auth_methods: ~c"publickey",
      preferred_algorithms: [public_key: [:"ssh-ed25519"]]
    )
  end

  def ssh_connect(port, options) do
    :ssh.connect(
      {127, 0, 0, 1},
      port,
      options ++
        [
          silently_accept_hosts: true,
          save_accepted_host: false,
          user_interaction: false,
          connect_timeout: 3000
        ],
      5000
    )
  end

  # Ephemeral generated credentials for the owned guest only. No workstation keys.
  @impl true
  def user_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:key]}
  def user_key(_, _), do: {:error, :not_found}
  @impl true
  def is_host_key(_, _, _, _, _), do: true
  @impl true
  def add_host_key(_, _, _, _), do: :ok

  def settings(port) do
    Map.put(%{"mode" => "ports", "eth0" => nil, "eth1" => nil}, port, %{
      "role" => "internet",
      "address" => NervesGate.Config.address_defaults()
    })
  end

  def propose(vm, settings) do
    Qemu.await(vm, "configuration available", & &1.actions["network.propose"].enabled)
    assert {:ok, trial} = Qemu.call(vm, :network_propose, [settings])
    Qemu.await(vm, "configuration ready to save", & &1.actions["network.confirm"].enabled)
    trial
  end

  def save(vm, settings) do
    trial = propose(vm, settings)
    assert :ok = Qemu.call(vm, :network_confirm, [trial])

    Qemu.await(
      vm,
      "settings saved",
      &(&1.network.setup_completed && &1.network.pending == nil && &1.network.desired == settings)
    )

    settings
  end

  def cable_cycle(vm) do
    try do
      Qemu.network(vm, %{cables: %{lan1: false}})

      Qemu.await(vm, "cable disconnected", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
      end)
    after
      Qemu.network(vm, %{cables: %{lan1: true}})
    end

    Qemu.await(vm, "link and address recovered", &addressed?/1)
  end

  def internet?(status) do
    addressed?(status) && status.connections.internet.health == "online" &&
      Enum.any?(status.connections.ports, &match?(%{name: "eth0", connection: :internet}, &1))
  end

  def addressed?(status) do
    Enum.any?(
      status.connections.ports,
      &match?(%{name: "eth0", link: true, addresses: [_ | _]}, &1)
    )
  end
end

defmodule NervesGate.CommissioningTest do
  use ExUnit.Case

  alias NervesGate.Commissioning
  alias NervesGate.Commissioning.Access
  alias NervesGate.TestInternetAdapter

  setup do
    {:ok, _pid} = TestInternetAdapter.reset()
    :ok
  end

  test "interface selection remains pure and excludes the uplink" do
    interfaces = [
      %{name: "eth0", kind: :ethernet},
      %{name: "eth1", kind: :ethernet},
      %{name: "wlan0", kind: :wifi}
    ]

    assert Access.commissioning_candidates(interfaces, "eth0") == [
             %{name: "wlan0", kind: :wifi},
             %{name: "eth1", kind: :ethernet}
           ]
  end

  test "machine moves through reconciling to active and waiting as hardware changes" do
    {:ok, interfaces} =
      Agent.start_link(fn ->
        [%{name: "eth0", kind: :ethernet}, %{name: "wlan0", kind: :wifi}]
      end)

    machine = start_machine(fn -> Agent.get(interfaces, & &1) end)
    assert {:ok, active} = Commissioning.enable(:commissioning, "eth0", machine)
    assert Enum.map(active, & &1.interface) == ["wlan0"]
    assert Commissioning.status(machine).state == :active

    Agent.update(interfaces, fn _ -> [%{name: "eth0", kind: :ethernet}] end)
    assert {:error, :no_interface} = Commissioning.heal(machine)
    assert Commissioning.status(machine).state == :waiting
    assert Commissioning.diagnostics(machine).blocked_by == :hardware

    Agent.update(interfaces, fn _ ->
      [%{name: "eth0", kind: :ethernet}, %{name: "eth1", kind: :ethernet}]
    end)

    assert :ok = Commissioning.heal(machine)
    assert Commissioning.status(machine).state == :active
  end

  test "passive reconciliation preserves public active state" do
    owner = self()

    machine =
      start_machine(
        fn ->
          [%{name: "eth0", kind: :ethernet}, %{name: "wlan0", kind: :wifi}]
        end,
        fn status -> send(owner, {:published, status}) end
      )

    assert {:ok, _active} = Commissioning.enable(:commissioning, "eth0", machine)
    drain_published()

    GenServer.cast(machine, {:tick, nil})
    assert_eventually(fn -> Commissioning.diagnostics(machine).state == :active end)
    statuses = drain_published()

    assert statuses != []
    assert Enum.all?(statuses, &(&1.state == :active))
  end

  test "disable clears active commissioning interfaces" do
    machine =
      start_machine(fn ->
        [%{name: "eth0", kind: :ethernet}, %{name: "wlan0", kind: :wifi}]
      end)

    assert {:ok, _active} = Commissioning.enable(:commissioning, "eth0", machine)
    assert :ok = Commissioning.disable(machine)

    assert Commissioning.status(machine) == %NervesGate.Commissioning.Status{
             state: :disabled,
             active: [],
             mode: :disabled
           }

    assert {:clear, "wlan0"} in TestInternetAdapter.state().calls
  end

  defp start_machine(hardware, publisher \\ fn _status -> :ok end) do
    name = String.to_atom("commissioning_machine_#{System.unique_integer([:positive])}")

    payload =
      Commissioning.new(
        adapter: TestInternetAdapter,
        hardware: hardware,
        publisher: publisher
      )

    {:ok, machine} = Commissioning.start_link(payload: payload, name: name)
    machine
  end

  defp drain_published(statuses \\ []) do
    receive do
      {:published, status} -> drain_published([status | statuses])
    after
      0 -> Enum.reverse(statuses)
    end
  end

  defp assert_eventually(function, attempts \\ 100)
  defp assert_eventually(function, 0), do: assert(function.())

  defp assert_eventually(function, attempts) do
    if function.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(function, attempts - 1)
    end
  end
end

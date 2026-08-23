defmodule NervesGateQEMU.RunnerTest do
  use ExUnit.Case, async: false

  alias NervesGateQEMU.Fault
  alias NervesGateQEMU.Runner
  alias NervesGateQEMU.Status

  setup do
    previous = System.get_env("NERVES_GATE_QEMU_STATE")

    root =
      Path.join(System.tmp_dir!(), "nerves_gate_qemu_test_#{System.unique_integer([:positive])}")

    System.put_env("NERVES_GATE_QEMU_STATE", root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: System.put_env("NERVES_GATE_QEMU_STATE", previous),
        else: System.delete_env("NERVES_GATE_QEMU_STATE")
    end)

    %{root: root}
  end

  test "defaults to three deterministic devices" do
    assert Enum.map(Runner.devices(), &{&1.id, &1.port}) == [
             {"M01", 4001},
             {"M02", 4002},
             {"M03", 4003}
           ]

    assert Enum.map(Runner.devices(), & &1.iframe_url) == [
             "http://m01.localhost:4001",
             "http://m02.localhost:4002",
             "http://m03.localhost:4003"
           ]
  end

  test "reads a variable topology manifest", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Runner.manifest_path(),
      Jason.encode!(%{
        "version" => 1,
        "next_index" => 6,
        "devices" => [
          %{"id" => "M02", "index" => 2},
          %{"id" => "M05", "index" => 5}
        ]
      })
    )

    assert Enum.map(Runner.devices(), &{&1.id, &1.port}) == [{"M02", 4002}, {"M05", 4005}]
  end

  test "tracks one semantic fault per device", %{root: root} do
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "faults.json"),
      Jason.encode!(%{"M01" => %{"kind" => "link_down"}})
    )

    [m01, m02 | _rest] = Runner.devices()
    assert Fault.status(m01) == :link_down
    assert Fault.link_state(m01) == :down
    assert Fault.status(m02) == :none

    assert :ok = Fault.clear("m01")
    assert Fault.status(m01) == :none
  end

  test "mutations reject a corrupt topology manifest", %{root: root} do
    File.mkdir_p!(root)
    File.write!(Runner.manifest_path(), "{not-json")

    assert {:error, {:invalid_topology_manifest, %Jason.DecodeError{}}} = Runner.scale(3)
  end

  test "status remains available when every VM is stopped" do
    assert %{devices: devices, observed_at: %DateTime{}} = Status.all()
    assert Enum.all?(devices, &(&1.vm == :stopped))
    assert Enum.all?(devices, &(&1.internet == :unknown))
  end
end

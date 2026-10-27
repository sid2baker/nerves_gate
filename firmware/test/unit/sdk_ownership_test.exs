defmodule NervesGate.SDKOwnershipTest do
  use ExUnit.Case, async: false
  alias NervesGate.Plugins.{Assignments, Owner}
  @moduletag :tmp_dir

  defmodule ResourceFixture do
    use Application
    def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end

  test "resource queries skip unassigned, disabled and other-plugin ports" do
    Owner.init()

    :ok =
      :application.load(
        {:application, :resources_fixture,
         [
           vsn: ~c"1.0.0",
           modules: [ResourceFixture],
           applications: [:kernel, :stdlib, :elixir],
           mod: {ResourceFixture, []}
         ]}
      )

    on_exit(fn ->
      Application.stop(:resources_fixture)
      Application.unload(:resources_fixture)
    end)

    Owner.bind(%{app: :resources_fixture, apps: [%{app: :resources_fixture}]}, {make_ref(), 1})
    :ok = Application.start(:resources_fixture)
    hardware = start_supervised!(NervesGate.Hardware)
    ports = for name <- ["ttyS3", "ttyS4", "can0"], do: %{name: name, present: true}
    :sys.replace_state(hardware, fn _ -> ports end)
    pid = Process.whereis(ResourceFixture)

    for assignments <- [
          %{},
          %{
            "ttyS4" => %{enabled: false, plugin: "resources_fixture"},
            "can0" => %{enabled: true, plugin: "another_plugin"}
          }
        ] do
      state = %{assignment_error: nil, assignments: assignments, entries: %{}}

      assert {:reply, {:ok, []}, ^state} =
               NervesGate.Plugins.handle_call(:resources, {pid, make_ref()}, state)
    end
  end

  test "assignments persist multiple ports for one plugin and keep missing intent", %{
    tmp_dir: dir
  } do
    ports = %{
      "ttyS3" => %{enabled: true, plugin: "modbus_plugin"},
      "ttyS4" => %{enabled: false, plugin: "modbus_plugin"}
    }

    file = Path.join(dir, "hardware.term")
    assert :ok = Assignments.persist(file, ports)
    assert {:ok, ^ports} = Assignments.read(file)
    bytes = File.read!(file)

    assert {:error, :invalid_hardware_assignments} =
             Assignments.persist(
               file,
               Map.put(ports, "ttyS0", %{enabled: true, plugin: "modbus_plugin"})
             )

    assert File.read!(file) == bytes
  end

  test "current-only metadata rejects trailing bytes, compression and malformed intent", %{
    tmp_dir: dir
  } do
    file = Path.join(dir, "hardware.term")

    for bytes <- [
          "invalid",
          :erlang.term_to_binary(%{}),
          :erlang.term_to_binary(
            %{
              schema: 1,
              ports: %{"ttyS3" => %{enabled: true, plugin: String.duplicate("p", 200)}}
            },
            [:compressed]
          ),
          :erlang.term_to_binary(%{schema: 1, ports: %{}}) <> "extra",
          :erlang.term_to_binary(%{schema: 1, ports: %{"ttyS3" => %{enabled: true, plugin: 1}}})
        ] do
      File.write!(file, bytes)
      assert {:error, :invalid_hardware_assignments} = Assignments.read(file)
      assert File.read!(file) == bytes
    end
  end

  test "protected, absent and wrong-kind resources cannot be assigned" do
    ports = [
      %{name: "ttyS3", present: true},
      %{name: "ttyS4", present: false},
      %{name: "can0", present: true}
    ]

    capabilities = %{"modbus_plugin" => [:serial]}
    assert :ok = Assignments.validate("ttyS3", true, "modbus_plugin", ports, capabilities)
    assert :ok = Assignments.validate("ttyS3", false, nil, ports, capabilities)
    assert :ok = Assignments.validate("ttyS4", false, nil, ports, capabilities)

    assert {:error, :invalid_hardware_assignment} =
             Assignments.validate("eth0", true, "modbus_plugin", ports, capabilities)

    assert {:error, :hardware_missing} =
             Assignments.validate("ttyS4", true, "modbus_plugin", ports, capabilities)

    assert {:error, :ineligible_plugin} =
             Assignments.validate("can0", true, "modbus_plugin", ports, capabilities)

    assert {:error, :ineligible_plugin} =
             Assignments.validate("ttyS3", true, "missing", ports, capabilities)
  end

  test "fixed SDK bridge forwards assignment queries from the actual caller", %{tmp_dir: dir} do
    previous = Application.get_env(:nerves_gate, :plugins_metadata)
    Application.put_env(:nerves_gate, :plugins_metadata, Path.join(dir, "plugins.term"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, :plugins_metadata, previous),
        else: Application.delete_env(:nerves_gate, :plugins_metadata)
    end)

    manager = start_supervised!(NervesGate.Plugins)
    :erlang.trace(manager, true, [:receive])
    caller = self()
    assert {:error, :application_not_running} = NervesGateSDK.Hardware.resources()
    assert_receive {:trace, ^manager, :receive, {:"$gen_call", {^caller, _}, :resources}}
  end

  test "assignment query derives actual caller rather than accepting an app name" do
    Owner.init()
    state = %{assignment_error: nil}

    assert {:reply, {:error, :application_not_running}, ^state} =
             NervesGate.Plugins.handle_call(:resources, {self(), make_ref()}, state)
  end
end

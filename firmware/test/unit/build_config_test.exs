defmodule NervesGate.BuildConfigTest do
  use ExUnit.Case, async: false

  test "only EC100 selects the ECM modem and all targets protect input before networking" do
    for target <- [:ec100, :em300, :x86_64] do
      config = Config.Reader.read!("config/config.exs", env: :dev, target: target)

      assert config[:nerves_runtime][:init_module] == NervesGate.Recovery.DataInit
      assert config[:nerves][:application_sort] == [init: [:nerves_runtime]]

      assert Regex.match?(
               ~r/\A[0-9a-f]{40}(?:-dirty)?\z/,
               config[:nerves][:firmware][:fw_vcs_identifier]
             )

      board = config[:nerves_gate][:board]

      # Hardware settings have one owner, not parallel top-level defaults.
      for key <- Map.keys(board), do: refute(Keyword.has_key?(config[:nerves_gate], key))

      case target do
        :ec100 ->
          assert board == %{
                   cellular: %{
                     interface: "wwan0",
                     sim_detect_level: 1,
                     config: %{
                       type: VintageNetECM,
                       vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
                     }
                   },
                   ports: %{
                     can: ["can0", "can1"],
                     serial: [
                       {"ttyS3", "rs485", "RS485 · automatic direction · 9600 8N1"},
                       {"ttyS4", "rs485", "RS485 · automatic direction · 9600 8N1"}
                     ]
                   },
                   indicators: %{
                     leds: %{run: "ec100:run", user1: "ec100:user1", user2: "ec100:user2"},
                     button: "gpio-keys"
                   },
                   data: {:ext4, "/sys/class/block/mmcblk0p3/dev"},
                   plugins_device: "/dev/mmcblk1p1"
                 }

          assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]

        :em300 ->
          # Unqualified EM300 peripherals stay disabled; ttyS5 belongs to the I/O domain.
          assert %{
                   cellular: nil,
                   indicators: nil,
                   data: {:ubifs, "/dev/ubi0_2"},
                   plugins_device: "/dev/mmcblk0p1",
                   ports: %{can: ["can0", "can1"], serial: serial}
                 } = board

          assert Enum.map(serial, &elem(&1, 0)) == ["ttyS1", "ttyS2", "ttyS3", "ttyS4"]
          assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]

          # Slot writes and data reset run outside fwup's env-partition destination.
          assert config[:nerves_runtime][:devpath] == "/dev/mtdblock2"
          assert config[:nerves_runtime][:fwup_extra_options] == ["--unsafe"]
          assert config[:ssh_subsystem_fwup][:fwup_extra_options] == ["--unsafe"]

        :x86_64 ->
          assert board == %{
                   cellular: nil,
                   ports: nil,
                   indicators: nil,
                   data: {:ext4, "/sys/class/block/vda4/dev"},
                   plugins_device: "/dev/vdb"
                 }

          # runtime.exs supplies USB and the real eth2 IP from the virtual disk serial.
          # There is no shared static management address in the compiled configuration.
          assert config[:vintage_net][:config] == []
      end
    end
  end

  test "QEMU runtime preserves the full dotted kernel hostname for management" do
    source = File.read!("config/runtime.exs") |> Code.string_to_quoted!()

    for address <- ["10.203.42.2", "172.30.42.3", "192.168.250.254"] do
      # Supply the kernel file contents, including its trailing newline. A short
      # hostname lookup would instead turn qemu-10.203.42.2 into qemu-10.
      runtime =
        Macro.prewalk(source, fn
          {{:., _, [{:__aliases__, _, [:File]}, :read!]}, _, ["/proc/sys/kernel/hostname"]} ->
            "qemu-#{address}\n"

          node ->
            node
        end)

      config =
        Config.Reader.eval!("config/runtime.exs", Macro.to_string(runtime), target: :x86_64)

      assert config[:nerves_gate][:development_node] == String.to_atom("nerves_gate@#{address}")

      {"usb0", usb_config} = List.keyfind(config[:vintage_net][:config], "usb0", 0)

      assert %{vintage_net_direct: %{hostname: "qemu-" <> ^address}} =
               VintageNetDirect.normalize(usb_config)

      assert {"eth2", %{ipv4: %{address: ^address, prefix_length: 24}}} =
               List.keyfind(config[:vintage_net][:config], "eth2", 0)
    end
  end

  test "Nerves build-plan metadata carries the configured source revision" do
    target = Mix.target()
    previous = Application.get_env(:nerves, :firmware)
    revision = String.duplicate("a", 40)

    try do
      Mix.target(:ec100)
      Application.put_env(:nerves, :firmware, fw_vcs_identifier: revision)
      callback = Mix.Project.get().project()[:nerves][:plan_callback]
      plan = callback.(%Nerves.BuildPlan{})
      assert plan.config.fw_vcs_identifier == revision
    after
      Mix.target(target)

      if previous,
        do: Application.put_env(:nerves, :firmware, previous),
        else: Application.delete_env(:nerves, :firmware)
    end
  end

  test "host builds start no device services and declare no board hardware" do
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    assert config[:nerves_gate][:services] == []
    refute Keyword.has_key?(config[:nerves_gate], :board)
  end

  test "code reload listeners are restricted to host development" do
    project = Mix.Project.get()
    previous_env = Mix.env()
    previous_target = Mix.target()
    previous_local = System.get_env("NERVES_GATE_LOCAL_DEPS")
    # EM300 is unpublished; its builds always use local system sources.
    System.put_env("NERVES_GATE_LOCAL_DEPS", "1")

    try do
      for {target, env} <- [
            host: :dev,
            host: :test,
            host: :docs,
            x86_64: :dev,
            ec100: :prod,
            em300: :prod
          ] do
        Mix.env(env)
        Mix.target(target)
        listeners = project.project()[:listeners]

        if {target, env} == {:host, :dev},
          do: assert(listeners == [Phoenix.CodeReloader]),
          else: assert(listeners == [])
      end
    after
      Mix.env(previous_env)
      Mix.target(previous_target)

      if previous_local,
        do: System.put_env("NERVES_GATE_LOCAL_DEPS", previous_local),
        else: System.delete_env("NERVES_GATE_LOCAL_DEPS")
    end
  end
end

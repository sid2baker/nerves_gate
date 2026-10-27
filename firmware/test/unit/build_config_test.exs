defmodule NervesGate.BuildConfigTest do
  use ExUnit.Case, async: false

  test "only EC100 selects the ECM modem and both targets protect input before networking" do
    for target <- [:ec100, :x86_64] do
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

      if target == :ec100 do
        assert board == %{
                 cellular: %{
                   interface: "wwan0",
                   sim_detect_level: 1,
                   config: %{
                     type: VintageNetECM,
                     vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
                   }
                 },
                 hardware_adapter: {NervesGate.Hardware.EC100, nil},
                 indicators_adapter: {NervesGate.Indicators.EC100, "/sys/class/leds"},
                 recovery_adapter: {NervesGate.Recovery.EC100, nil},
                 data_partition: "/sys/class/block/mmcblk0p3/dev",
                 apps_device: "/dev/mmcblk1p1"
               }

        assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]
      else
        assert board == %{
                 cellular: nil,
                 hardware_adapter: nil,
                 indicators_adapter: nil,
                 recovery_adapter: nil,
                 data_partition: "/sys/class/block/vda4/dev",
                 apps_device: "/dev/vdb"
               }

        assert config[:vintage_net][:config] == [
                 {"usb0", %{type: VintageNetDirect}},
                 {"eth2",
                  %{
                    type: VintageNetEthernet,
                    ipv4: %{method: :static, address: "192.168.77.2", prefix_length: 24}
                  }}
               ]
      end
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

    try do
      for {target, env} <- [host: :dev, host: :test, host: :docs, x86_64: :dev, ec100: :prod] do
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
    end
  end
end

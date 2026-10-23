defmodule NervesGate.BuildConfigTest do
  use ExUnit.Case, async: false

  test "only EC100 selects the ECM modem and both targets protect input before networking" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!("config/config.exs", env: :dev, target: target)

      assert config[:nerves_runtime][:init_module] == NervesGate.Recovery.DataInit
      assert config[:nerves][:application_sort] == [init: [:nerves_runtime]]

      board = config[:nerves_gate][:board]

      # Hardware settings have one owner, not parallel top-level defaults.
      for key <- Map.keys(board), do: refute(Keyword.has_key?(config[:nerves_gate], key))

      if target == :ec100 do
        assert board == %{
                 cellular: %{
                   interface: "wwan0",
                   config: %{type: VintageNetECM, vintage_net_ecm: %{at_tty: "ttyUSB2"}}
                 },
                 buses_adapter: {NervesGate.Buses.EC100, nil},
                 indicators_adapter: {NervesGate.Indicators.EC100, "/sys/class/leds"},
                 recovery_adapter: {NervesGate.Recovery.EC100, nil},
                 data_partition: "/sys/class/block/mmcblk0p3/dev",
                 apps_device: "/dev/mmcblk1p1"
               }

        assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]
      else
        assert board == %{
                 cellular: nil,
                 buses_adapter: nil,
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

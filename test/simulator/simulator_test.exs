defmodule SimulatorTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "configuration resolves firmware paths and assigns private device addresses", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "simulator.exs")

    File.write!(path, """
    %{firmware_project: "firmware", firmware: "firmware/gate.fw",
      devices: %{gateway_b: %{}, gateway_a: %{network: %{internet: :lan2}}}}
    """)

    config = Simulator.config(path, dir)
    assert config.firmware == Path.join(dir, "firmware/gate.fw")
    assert config.factory_firmware == config.firmware
    assert config.firmware_project == Path.join(dir, "firmware")
    assert config.raw.firmware == "firmware/gate.fw"

    start_supervised!({Simulator, config})

    view = Simulator.subscribe(node())
    assert view.status == :stopped

    assert [
             %{id: :gateway_a, address: "127.0.0.2", internet: :lan2},
             %{id: :gateway_b, address: "127.0.0.3", internet: :lan1}
           ] = Enum.map(view.devices, &Map.take(&1, [:id, :address, :internet]))
  end
end

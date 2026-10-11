defmodule NervesGate.EC100IndicatorsTest do
  use ExUnit.Case, async: true
  alias NervesGate.Indicators.EC100

  setup do
    root = Path.join(System.tmp_dir!(), "gate-indicators-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "discovery requires gpio-keys AND KEY_PROG1, never a fixed input index", %{root: root} do
    input(root, "event0", "other keyboard", "100000 0 0 0 0")
    input(root, "event2", "gpio-keys", "800000 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
    input(root, "event7", "gpio-keys", "100000 0 0 0 0")
    assert {:ok, "/dev/input/event7"} = EC100.button_path(root)
    input(root, "event8", "gpio-keys", "100000 0 0 0 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
  end

  test "malformed and missing capabilities do not match", %{root: root} do
    input(root, "event3", "gpio-keys", "invalid 0 0 0 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
    File.rm!(Path.join(root, "event3/device/capabilities/key"))
    assert {:error, :button_unavailable} = EC100.button_path(root)
  end

  test "raw binary brightness is read and verified without changing the trigger", %{root: root} do
    led(root, "0", "[none] timer heartbeat")
    assert {:ok, 0} = EC100.read_led(root)
    assert :ok = EC100.write_led(1, root)
    assert {:ok, 1} = EC100.read_led(root)
    assert :ok = EC100.write_led(0, root)
    assert File.read!(Path.join(root, "trigger")) == "[none] timer heartbeat"
  end

  test "trigger-controlled and incompatible LEDs are never taken over", %{root: root} do
    led(root, "1", "none [heartbeat]")
    assert {:error, :led_unavailable} = EC100.read_led(root)
    assert {:error, :led_unavailable} = EC100.write_led(0, root)
    assert File.read!(Path.join(root, "brightness")) == "1"
    File.write!(Path.join(root, "trigger"), "[none]")
    File.write!(Path.join(root, "max_brightness"), "255")
    assert {:error, :led_unavailable} = EC100.read_led(root)
    assert {:error, :led_unavailable} = EC100.write_led(0, root)
    assert File.read!(Path.join(root, "brightness")) == "1"
  end

  test "missing LED and invalid raw values are unavailable", %{root: root} do
    assert {:error, :led_unavailable} = EC100.read_led(root)
    led(root, "invalid", "[none]")
    assert {:error, :led_unavailable} = EC100.read_led(root)
    File.write!(Path.join(root, "brightness"), "0")
    File.rm!(Path.join(root, "trigger"))
    assert {:ok, 0} = EC100.read_led(root)
  end

  defp input(root, name, label, bitmap) do
    device = Path.join([root, name, "device"])
    File.mkdir_p!(Path.join(device, "capabilities"))
    File.write!(Path.join(device, "name"), label <> "\n")
    File.write!(Path.join(device, "capabilities/key"), bitmap <> "\n")
  end

  defp led(root, brightness, trigger) do
    File.write!(Path.join(root, "brightness"), brightness)
    File.write!(Path.join(root, "max_brightness"), "1\n")
    File.write!(Path.join(root, "trigger"), trigger)
  end
end

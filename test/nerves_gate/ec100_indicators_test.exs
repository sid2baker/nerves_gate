defmodule NervesGate.EC100IndicatorsTest do
  use ExUnit.Case, async: true
  alias NervesGate.Indicators.EC100
  @moduletag tmp_dir: true

  test "discovery requires gpio-keys AND KEY_PROG1, never a fixed input index", %{tmp_dir: root} do
    input(root, "event0", "other keyboard", "100000 0 0 0 0")
    input(root, "event2", "gpio-keys", "800000 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
    input(root, "event7", "gpio-keys", "100000 0 0 0 0")
    assert {:ok, "/dev/input/event7"} = EC100.button_path(root)
    input(root, "event8", "gpio-keys", "100000 0 0 0 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
  end

  test "malformed and missing capabilities do not match", %{tmp_dir: root} do
    input(root, "event3", "gpio-keys", "invalid 0 0 0 0")
    assert {:error, :button_unavailable} = EC100.button_path(root)
    File.rm!(Path.join(root, "event3/device/capabilities/key"))
    assert {:error, :button_unavailable} = EC100.button_path(root)
  end

  test "all three mapped LEDs support binary brightness without changing triggers", %{
    tmp_dir: root
  } do
    for name <- [:run, :user1, :user2] do
      path = led(root, name, "0", "[none] timer transient pattern")
      assert {:ok, 0} = EC100.read_led(name, root)
      assert :ok = EC100.write_led(name, 1, root)
      assert {:ok, 1} = EC100.read_led(name, root)
      assert :ok = EC100.write_led(name, 0, root)
      assert File.read!(Path.join(path, "trigger")) == "[none] timer transient pattern"
    end
  end

  test "trigger-controlled and incompatible LEDs are never taken over", %{tmp_dir: root} do
    path = led(root, :run, "1", "none [heartbeat]")
    assert {:error, :led_unavailable} = EC100.read_led(:run, root)
    assert {:error, :led_unavailable} = EC100.write_led(:run, 0, root)
    assert File.read!(Path.join(path, "brightness")) == "1"
    File.write!(Path.join(path, "trigger"), "[none]")
    File.write!(Path.join(path, "max_brightness"), "255")
    assert {:error, :led_unavailable} = EC100.read_led(:run, root)
    assert {:error, :led_unavailable} = EC100.write_led(:run, 0, root)
    assert File.read!(Path.join(path, "brightness")) == "1"
  end

  test "missing LED and invalid raw values are unavailable", %{tmp_dir: root} do
    assert {:error, :led_unavailable} = EC100.read_led(:run, root)
    path = led(root, :run, "invalid", "[none]")
    assert {:error, :led_unavailable} = EC100.read_led(:run, root)
    File.write!(Path.join(path, "brightness"), "0")
    File.rm!(Path.join(path, "trigger"))
    assert {:ok, 0} = EC100.read_led(:run, root)
    assert {:error, :led_unavailable} = EC100.read_led(:user1, root)
  end

  defp input(root, name, label, bitmap) do
    device = Path.join([root, name, "device"])
    File.mkdir_p!(Path.join(device, "capabilities"))
    File.write!(Path.join(device, "name"), label <> "\n")
    File.write!(Path.join(device, "capabilities/key"), bitmap <> "\n")
  end

  defp led(root, name, brightness, trigger) do
    path = Path.join(root, "ec100:#{name}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "brightness"), brightness)
    File.write!(Path.join(path, "max_brightness"), "1\n")
    File.write!(Path.join(path, "trigger"), trigger)
    path
  end
end

defmodule NervesGate.StorageSlotTest do
  use ExUnit.Case, async: true
  alias NervesGate.Storage

  @slot "devices/platform/ff780000.usb/usb1/1-1/1-1.3"

  setup do
    sys = Path.join(System.tmp_dir!(), "storage-slot-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(sys) end)
    %{sys: sys}
  end

  defp disk(sys, name, parent, partitions) do
    dir = Path.join([sys, parent, name])
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(sys, "class/block"))

    File.ln_s!(
      Path.relative_to(dir, Path.join(sys, "class/block"), force: true),
      Path.join(sys, "class/block/#{name}")
    )

    for n <- partitions do
      part = Path.join(dir, "#{name}#{n}")
      File.mkdir_p!(part)
      File.write!(Path.join(part, "partition"), "#{n}\n")

      File.ln_s!(
        Path.relative_to(part, Path.join(sys, "class/block"), force: true),
        Path.join(sys, "class/block/#{name}#{n}")
      )
    end
  end

  test "resolves the declared partition below the slot, whatever the kernel name", %{sys: sys} do
    disk(sys, "sdb", @slot <> "/1-1.3:1.0/host0/target0:0:0/0:0:0:0/block", [1, 2])
    disk(sys, "sda", "devices/platform/ff780000.usb/usb1/1-1/1-1.4/host1/block", [1])

    assert Storage.slot_device(@slot, 1, sys) == "/dev/sdb1"
    assert Storage.slot_device(@slot, 2, sys) == "/dev/sdb2"
    assert Storage.slot_device(@slot, nil, sys) == "/dev/sdb"
    assert Storage.slot_device(@slot, 3, sys) == nil
  end

  test "an empty slot or a sibling port prefix is no card", %{sys: sys} do
    disk(sys, "sda", "devices/platform/ff780000.usb/usb1/1-1/1-1.30/block", [1])
    assert Storage.slot_device(@slot, 1, sys) == nil
  end
end

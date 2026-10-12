defmodule NervesGate.RecoveryTest do
  use ExUnit.Case, async: true
  alias NervesGate.Recovery.{DataInit, EC100}

  test "hardware recovery and boot initialization are unavailable on host" do
    assert EC100.execute(:factory_reset, nil) == {:error, :recovery_unavailable}
    assert EC100.execute(:reboot, nil) == {:error, :recovery_unavailable}
    assert DataInit.start_link([]) == {:error, :recovery_unavailable}
  end

  test "boot requires the entire expected partition mounted rw ext4 at /root" do
    root = mount("/root")
    assert EC100.data_mount([root], "179:3") == {:ok, root}

    for invalid <- [
          [],
          [root, root],
          [%{root | mount_point: "/data"}],
          [%{root | major_minor: "179:1"}],
          [%{root | root: "/subdirectory"}],
          [%{root | fs_type: "squashfs"}],
          [%{root | mount_options: ["ro"]}],
          [%{root | super_options: ["ro"]}],
          [%{root | mount_options: []}]
        ] do
      assert EC100.data_mount(invalid, "179:3") == {:error, :data_partition_unavailable}
    end
  end

  test "unmount list includes bind aliases child-first, but not firmware on the same disk" do
    mounts = [
      mount("/root"),
      mount("/root/bind", 2),
      mount("/other\\040alias", 3),
      %{mount("/") | major_minor: "179:1", fs_type: "squashfs"}
    ]

    assert EC100.data_mounts(mounts, "179:3") == ["/root/bind", "/other alias", "/root"]
    assert EC100.data_mounts(mounts, "179:4") == []
  end

  test "admission is once-only across workers; failure never clears the latch" do
    key = admission_key()
    workers = for _ <- 1..8, do: Task.async(fn -> EC100.admit(:recovery, key) end)
    results = Enum.map(workers, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :recovery_already_requested})) == 7
    assert EC100.admit(:update, key) == {:error, :recovery_already_requested}
  end

  test "upload admission blocks recovery until reboot, including failed or pending uploads" do
    key = admission_key()
    assert EC100.admit(:update, key) == :ok
    assert EC100.admit(:recovery, key) == {:error, :firmware_update_pending}
    assert EC100.admit(:update, key) == :ok
  end

  defp admission_key do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(key) end)
    key
  end

  defp mount(path, id \\ 1) do
    %{
      mount_id: id,
      mount_point: path,
      major_minor: "179:3",
      root: "/",
      fs_type: "ext4",
      mount_options: ["rw"],
      super_options: ["rw"]
    }
  end
end

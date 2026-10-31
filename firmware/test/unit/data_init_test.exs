defmodule NervesGate.DataInitTest do
  use ExUnit.Case, async: true
  alias NervesGate.Recovery.DataInit

  defp mount(overrides) do
    Map.merge(
      %{
        mount_id: 30,
        parent_id: 1,
        major_minor: "179:3",
        root: "/",
        mount_point: "/root",
        mount_options: ["rw", "nodev"],
        fs_type: "ext4",
        mount_source: "/dev/mmcblk0p3",
        super_options: ["rw"]
      },
      overrides
    )
  end

  test "block-device data is identified by its device number" do
    data = mount(%{})
    assert {:ok, ^data} = DataInit.data_mount([data], {"ext4", :major_minor, "179:3"})

    assert {:error, %{code: "data_partition_unavailable"}} =
             DataInit.data_mount([data], {"ext4", :major_minor, "179:5"})
  end

  test "UBIFS data is identified by its volume, not its anonymous device number" do
    data = mount(%{major_minor: "0:22", fs_type: "ubifs", mount_source: "/dev/ubi0_2"})
    assert {:ok, ^data} = DataInit.data_mount([data], {"ubifs", :mount_source, "/dev/ubi0_2"})

    for wrong <- [
          %{mount_source: "/dev/ubi0_0"},
          %{fs_type: "ext4"},
          %{mount_options: ["ro"]},
          %{super_options: ["ro"]},
          %{root: "/nested"}
        ] do
      assert {:error, %{message: "The data partition is not mounted read-write as ubifs."}} =
               DataInit.data_mount(
                 [Map.merge(data, wrong)],
                 {"ubifs", :mount_source, "/dev/ubi0_2"}
               )
    end
  end

  test "a missing or doubly mounted /root is unavailable" do
    assert {:error, _} = DataInit.data_mount([], {"ext4", :major_minor, "179:3"})

    assert {:error, _} =
             DataInit.data_mount(
               [mount(%{}), mount(%{mount_id: 31})],
               {"ext4", :major_minor, "179:3"}
             )
  end
end

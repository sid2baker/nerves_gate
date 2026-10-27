defmodule Workbench.DeviceUpdateTest do
  use ExUnit.Case, async: true
  alias Workbench.DeviceUpdate
  @moduletag :tmp_dir

  test "only changed identities under an existing version conflict" do
    old = %{artifacts: %{"1.0.0" => %{sha256: "old", source: :firmware}}}
    saved = %{"plugin" => old}
    assert [] = DeviceUpdate.conflicts(saved, saved)

    assert [] =
             DeviceUpdate.conflicts(saved, %{
               "plugin" => %{artifacts: %{"1.0.1" => %{sha256: "new"}}}
             })

    assert [{"plugin", "1.0.0"}] =
             DeviceUpdate.conflicts(saved, %{
               "plugin" => %{artifacts: %{"1.0.0" => %{sha256: "new"}}}
             })

    assert [{"plugin", "1.0.0"}] =
             DeviceUpdate.conflicts(saved, %{
               "plugin" => %{artifacts: %{"1.0.0" => %{sha256: "old", source: :development}}}
             })
  end

  test "confirmation binds identity, host, source and exact image digest" do
    review = %{
      "serial" => "device",
      "address" => "host",
      "source_revision" => "rev",
      "sha256" => "digest",
      "verify_ssh" => true
    }

    identity = %{"serial" => "device"}
    image = %{"meta-vcs-identifier" => "rev"}
    assert :ok = DeviceUpdate.verify_review!(review, identity, "host", image, "digest")

    for {key, value} <- [
          {"serial", "other"},
          {"address", "other"},
          {"source_revision", "other"},
          {"sha256", "other"},
          {"verify_ssh", false}
        ] do
      assert_raise RuntimeError, fn ->
        DeviceUpdate.verify_review!(
          Map.put(review, key, value),
          identity,
          "host",
          image,
          "digest"
        )
      end
    end
  end

  test "catalog is read from the supplied firmware archive, not checkout files", %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    inventory = Path.join(root, "srv/erlang/lib/nerves_gate-test/priv/plugins/inventory.term")
    File.mkdir_p!(Path.dirname(inventory))
    catalog = %{"fixture" => %{artifacts: %{"1.0" => %{sha256: "fixture"}}}}
    File.write!(inventory, :erlang.term_to_binary(%{schema: 2, entries: catalog}))
    squash = Path.join(dir, "rootfs.img")

    {_, 0} =
      System.cmd("mksquashfs", [root, squash, "-noappend", "-no-progress", "-processors", "1"])

    archive = Path.join(dir, "fixture.fw")

    {:ok, _} =
      :zip.create(String.to_charlist(archive), [{~c"data/rootfs.img", File.read!(squash)}])

    assert ^catalog = DeviceUpdate.catalog!(archive)
  end

  test "missing firmware fails before contacting any device", %{tmp_dir: dir} do
    assert {:error, _} =
             DeviceUpdate.update("not-contacted.invalid", Path.join(dir, "missing.fw"))
  end
end

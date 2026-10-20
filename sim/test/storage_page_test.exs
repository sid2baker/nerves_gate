defmodule NervesGateSim.StoragePageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp page(storage, format_card \\ nil) do
    render_component(&NervesGateWeb.StorageLive.render/1,
      projection: %{storage: Map.merge(NervesGate.Storage.unavailable(), storage)},
      format_card: format_card
    )
  end

  test "no card can be skipped without showing an erase button" do
    html = page(%{available: true})
    assert html =~ "No readable SD card detected"
    assert html =~ "storage-skip"
    refute html =~ "id=\"storage-format\""
    refute html =~ "id=\"storage-use\""
  end

  test "a prepared card offers preservation and a separate erase confirmation" do
    card = %{available: true, present: true, filesystem: "ext4", card_id: "card-a"}
    html = page(card)
    assert html =~ "Use this card — keep data"
    refute html =~ "storage-format-form"
    html = page(card, "card-a")
    assert html =~ "storage-format-form"
    assert html =~ "permanently erased"
    assert html =~ "name=\"erase\""
  end

  test "FAT cards cannot be used as-is and replacement invalidates confirmation" do
    html =
      page(%{available: true, present: true, filesystem: "FAT32", card_id: "card-b"}, "card-a")

    refute html =~ "id=\"storage-use\""
    assert html =~ "The detected card changed"
    assert html =~ "Format for applications"
  end

  test "busy state and backend failures are visible" do
    html =
      page(%{
        available: true,
        present: true,
        operation: :format,
        error: NervesGate.Error.from(:storage_format_failed)
      })

    assert html =~ "Formatting and mounting"
    assert html =~ "Formatting failed"
    assert html =~ "disabled"
  end
end

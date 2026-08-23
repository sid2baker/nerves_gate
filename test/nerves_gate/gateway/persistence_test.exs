defmodule NervesGate.Gateway.PersistenceTest do
  use ExUnit.Case, async: true

  alias NervesGate.Gateway.{Persistence, Settings}
  alias NervesGate.Storage
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:persistence)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "hydration removes legacy files and creates both firmware slots", %{root: root} do
    File.mkdir_p!(root)

    for name <- ~w(setup.json network.json cluster.json device.json settings-change.json) do
      File.write!(Storage.path(name, root), "legacy")
    end

    assert {:ok, hydration} = Persistence.hydrate(root, firmware())
    refute hydration.current["configured"]
    assert settings(root, "a")["firmware"] == tag("a")
    assert settings(root, "b")["firmware"] == tag("b")

    assert Path.wildcard(Storage.path("*.json", root)) |> Enum.sort() ==
             [
               Persistence.settings_path("a", root),
               Persistence.settings_path("b", root)
             ]
  end

  test "candidate promotion replaces only the selected slot", %{root: root} do
    active = Settings.default(tag("a")) |> Map.put("name", "active")
    candidate = Settings.default(tag("a")) |> Map.put("name", "candidate")
    other = Settings.default(tag("b")) |> Map.put("name", "other")

    assert :ok = Persistence.write_slot(active, "a", root)
    assert :ok = Persistence.write_slot(other, "b", root)
    assert :ok = Persistence.write_candidate(candidate, root)

    assert :ok = Persistence.promote_candidate("a", root)
    assert settings(root, "a")["name"] == "candidate"
    assert settings(root, "b")["name"] == "other"
    refute File.exists?(Persistence.candidate_path(root))
  end

  defp settings(root, slot) do
    {:ok, settings} =
      Storage.read_json(Persistence.settings_path(slot, root), &Settings.validate/1, nil)

    settings
  end

  defp firmware do
    %{active: "a", slots: %{"a" => tag("a"), "b" => tag("b")}}
  end

  defp tag(slot) do
    %{"slot" => slot, "uuid" => "firmware-#{slot}", "version" => "1.0.0"}
  end
end

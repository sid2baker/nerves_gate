defmodule Workbench.SessionContractTest do
  use ExUnit.Case, async: false
  alias Workbench.Session

  test "identity and mutation compatibility are independent" do
    expected = %{
      root: "/checkout",
      id: "current",
      compatibility: %{protocol: 1, sdk: "sdk", platform: "platform", inputs: %{}}
    }

    remote = Map.merge(expected, %{loaded_sdk: "sdk", loaded_platform: "platform"})
    assert :ok = Session.validate(remote, expected, true)

    for changed <- [%{expected | id: "replaced"}, %{expected | root: "/foreign"}] do
      assert {:error, _} = Session.validate(remote, changed)
      assert {:error, _} = Session.validate(remote, changed, true)
    end

    stale = put_in(remote.compatibility.inputs, %{"protocol.ex" => "old"})
    assert :ok = Session.validate(stale, expected)
    assert {:error, reason} = Session.validate(stale, expected, true)
    assert reason =~ "restart"
    assert {:error, _} = Session.validate(%{remote | loaded_sdk: "old"}, expected, true)
    assert {:error, _} = Session.validate(%{remote | loaded_platform: "old"}, expected, true)
  end

  test "fingerprint has a small explicit manifest and ignores unrelated files" do
    root = Path.join(System.tmp_dir!(), "session-manifest-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for path <- Session.manifest() ++ ["VERSION", "sdk/VERSION"] do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(Workbench.root(), path), target)
    end

    initial = Session.compatibility(root)
    assert length(Session.manifest()) == 5
    assert "lib/workbench/jobs.ex" in Session.manifest()
    assert "lib/scenarios/runner.ex" in Session.manifest()
    assert "sdk/lib/nerves_gate_sdk/backend.ex" in Session.manifest()
    File.write!(Path.join(root, "unrelated.md"), "documentation")
    assert Session.compatibility(root) == initial
    File.write!(Path.join(root, "lib/workbench/jobs.ex"), "changed contract")
    refute Session.compatibility(root) == initial
  end

  test "owners reject a replaced-session envelope before interpreting a write" do
    {:ok, jobs} = Workbench.Jobs.init(nil)
    expected = %{Session.identity() | id: "not-this-session"}

    assert {:reply, {:error, _}, ^jobs} =
             Workbench.Jobs.handle_call(
               {:admit, expected, {:build, "ec100"}},
               {self(), make_ref()},
               jobs
             )

    runner = %{sentinel: :unchanged}

    assert {:reply, {:error, _}, ^runner} =
             Scenarios.Runner.handle_call(
               {:admit, expected, {:lifecycle, "reset"}},
               {self(), make_ref()},
               runner
             )
  end

  test "checkout aliases canonicalize to the same identity" do
    alias_path =
      Path.join(System.tmp_dir!(), "checkout-link-#{System.unique_integer([:positive])}")

    File.ln_s!(Workbench.root(), alias_path)
    on_exit(fn -> File.rm!(alias_path) end)
    assert Session.canonical_root(alias_path) == Session.canonical_root(Workbench.root())
  end
end

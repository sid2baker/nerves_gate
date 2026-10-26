defmodule NervesGate.ReviewedInstallTest do
  use ExUnit.Case, async: false
  alias NervesGate.Apps
  alias NervesGate.Apps.Artifact

  setup_all do
    [{module, beam}] =
      Code.compile_string("""
      defmodule ReviewedInstallFixture do
        use Application
        def start(_, _), do: raise("Reviewed installation must never start an app")
      end
      """)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    %{fixture_module: module, beam: beam}
  end

  @tag :tmp_dir
  test "a lost install owner reports unknown and cleans only the private staging file", %{
    tmp_dir: unrelated
  } do
    refute Process.whereis(Apps)

    dir =
      Path.join(
        System.tmp_dir!(),
        "nerves-gate-app-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    staged = Path.join(dir, "application.ez")
    retained = Path.join(dir, "retain")
    File.write!(staged, "package")
    File.write!(retained, "evidence")
    assert Apps.install_reviewed(staged, %{}) == %{outcome: "unknown"}
    refute File.exists?(staged)
    assert File.read!(retained) == "evidence"
    outside = Path.join(unrelated, "application.ez")
    File.write!(outside, "unrelated")
    assert Apps.install_reviewed(outside, %{}) == %{outcome: "unknown"}
    assert File.read!(outside) == "unrelated"
  end

  @tag :tmp_dir
  test "new install rejects a changed hash, package identity or existing entry before any storage effect",
       %{tmp_dir: dir, fixture_module: module, beam: beam} do
    spec =
      {:application, :reviewed_fixture,
       [
         vsn: ~c"1.0.0",
         modules: [module],
         applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
         mod: {module, []},
         env: [nerves_gate_sdk_requirement: "~> 0.2.0-dev"]
       ]}

    files = [
      {~c"reviewed_fixture-1.0.0/ebin/reviewed_fixture.app",
       IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))},
      {String.to_charlist("reviewed_fixture-1.0.0/ebin/#{module}.beam"), beam}
    ]

    path = Path.join(dir, "fixture.ez")
    {:ok, _} = :zip.create(to_charlist(path), files)
    assert {:ok, package, _bytes, sha} = Artifact.read(path)

    expected = %{
      app: "reviewed_fixture",
      version: "1.0.0",
      sha256: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower),
      card_id: "reviewed-card"
    }

    idle = %{}
    # No Storage process or device backend exists in this test. Admission must
    # reject these requests before consulting or changing hardware/storage.
    for altered <- [
          %{expected | sha256: "changed"},
          %{expected | app: "other"},
          %{expected | version: "2.0.0"}
        ] do
      assert {:error, :review_changed} = Artifact.review(package, sha, altered, idle)
    end

    installed = %{expected.app => %{enabled: true}}
    assert {:error, :review_changed} = Artifact.review(package, sha, expected, installed)
    assert {:error, :invalid_review} = Artifact.review(package, sha, %{}, idle)
  end
end

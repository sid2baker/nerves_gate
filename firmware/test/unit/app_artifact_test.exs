defmodule NervesGate.AppArtifactTest do
  use ExUnit.Case, async: false
  alias NervesGate.Apps.{Artifact, Loader, Metadata}
  alias NervesGateSDK.Package
  @moduletag :tmp_dir

  setup_all do
    beams =
      Code.compile_string("""
      defmodule ArtifactFixture do
        use Application
        def start(_, _) do
          send(Application.fetch_env!(:nerves_gate, :artifact_sink), :unexpected_start)
          Supervisor.start_link([], strategy: :one_for_one)
        end
      end
      defmodule ArtifactFixture.Preload do
        @on_load :load
        def load do
          if Application.get_env(:nerves_gate, :artifact_fail_load, false), do: :error, else: :ok
        end
      end
      """)

    for {module, _} <- beams do
      :code.delete(module)
      :code.soft_purge(module)
    end

    %{beams: beams}
  end

  setup %{tmp_dir: dir, beams: beams} do
    Application.put_env(:nerves_gate, :artifact_sink, self())

    spec =
      {:application, :artifact_fixture,
       [
         vsn: ~c"1.0.0",
         modules: Enum.map(beams, &elem(&1, 0)),
         applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
         mod: {ArtifactFixture, []},
         env: [nerves_gate_sdk_requirement: "~> 0.2.0-dev"]
       ]}

    files = [
      {~c"artifact_fixture-1.0.0/ebin/artifact_fixture.app",
       IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))}
      | Enum.map(beams, fn {module, beam} ->
          {String.to_charlist("artifact_fixture-1.0.0/ebin/#{module}.beam"), beam}
        end)
    ]

    {:ok, {_, bytes}} = :zip.create(~c"fixture.ez", files, [:memory])
    {:ok, package} = Package.read_binary(bytes)
    root = Path.join(dir, "installed")
    File.mkdir!(root)
    File.write!(Path.join(root, "package.ez"), bytes)
    :ok = Package.extract(package, Path.join(root, "content"))
    artifact = Artifact.describe(package, Artifact.hash(bytes), root, bytes)

    on_exit(fn ->
      Application.delete_env(:nerves_gate, :artifact_fail_load)
      Application.delete_env(:nerves_gate, :artifact_sink)
      Application.unload(:artifact_fixture)
      Enum.each(artifact.paths, &:code.del_path(String.to_charlist(&1)))

      for module <- artifact.modules do
        :code.delete(module)
        :code.soft_purge(module)
      end
    end)

    %{artifact: artifact, package: package, bytes: bytes}
  end

  test "verified content is bound to its archive, identity and complete file tree", %{
    artifact: artifact
  } do
    descriptor = Artifact.descriptor(artifact)

    assert {:ok, verified, _} =
             Artifact.open(artifact.root, "artifact_fixture", "1.0.0", descriptor)

    assert verified.sha256 == artifact.sha256
    extra = Path.join(artifact.root, "content/unregistered")
    File.mkdir!(extra)

    assert {:error, :artifact_modified} =
             Artifact.open(artifact.root, "artifact_fixture", "1.0.0", descriptor)

    File.rmdir!(extra)
    File.ln_s!("/", extra)

    assert {:error, :artifact_modified} =
             Artifact.open(artifact.root, "artifact_fixture", "1.0.0", descriptor)
  end

  test "modified BEAM and archive bytes are rejected", %{artifact: artifact} do
    descriptor = Artifact.descriptor(artifact)
    path = Path.join(hd(artifact.paths), "Elixir.ArtifactFixture.beam")
    original = File.read!(path)
    File.write!(path, "changed")

    assert {:error, :artifact_modified} =
             Artifact.open(artifact.root, "artifact_fixture", "1.0.0", descriptor)

    File.write!(path, original)
    archive = Path.join(artifact.root, "package.ez")
    File.write!(archive, File.read!(archive) <> "changed")

    assert {:error, :artifact_modified} =
             Artifact.open(artifact.root, "artifact_fixture", "1.0.0", descriptor)
  end

  test "failed actual preload cleans every acquired path/spec/module without starting OTP", %{
    artifact: artifact,
    package: package
  } do
    before = :code.get_path()
    kernel = Application.spec(:kernel)
    Application.put_env(:nerves_gate, :artifact_fail_load, true)

    activation = %{
      artifact: artifact,
      owner: %{app: "artifact_fixture", generation: {make_ref(), 1}},
      phase: :prepared,
      started: []
    }

    assert {:error, :module_load_failed, partial} =
             Loader.activate(activation, package, fn _ -> :ok end)

    assert partial.phase == :loading
    refute_receive :unexpected_start
    assert :ok = Loader.unload(partial)
    assert :code.get_path() == before
    assert Application.spec(:artifact_fixture) == nil
    assert Application.spec(:kernel) == kernel
    for module <- artifact.modules, do: assert(:code.is_loaded(module) == false)
  end

  test "stored reservations survive an unreadable stopped artifact", %{
    artifact: artifact,
    package: package
  } do
    descriptor = Artifact.descriptor(artifact)
    other = %{active_version: "1.0.0", artifacts: %{"1.0.0" => descriptor}}

    assert {:error, :application_conflict} =
             Artifact.validate(package, %{"other_owner" => other}, "artifact_fixture", nil)
  end

  test "metadata has a current-only schema and preserves catalog identity", %{
    artifact: artifact,
    tmp_dir: dir
  } do
    descriptor = Artifact.descriptor(artifact)

    entries = %{
      "artifact_fixture" => %{
        enabled: false,
        active_version: "1.0.0",
        previous_version: nil,
        generation: 0,
        artifacts: %{"1.0.0" => descriptor}
      }
    }

    path = Path.join(dir, "apps.term")
    assert :ok = Metadata.persist(path, entries)
    assert {:ok, ^entries} = Metadata.read(path)
    original = File.read!(path)
    File.write!(path, original <> "trailing")
    assert {:error, :invalid_app_metadata} = Metadata.read(path)
    File.write!(path, :erlang.term_to_binary(entries))
    assert {:error, :invalid_app_metadata} = Metadata.read(path)
    assert {:error, :invalid_app_metadata} = Metadata.persist(path, %{"invalid" => %{}})
  end
end

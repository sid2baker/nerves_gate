defmodule NervesGate.PluginArtifactTest do
  use ExUnit.Case, async: false
  alias NervesGate.Plugins.{Artifact, Bundled, Loader, Metadata}
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

    assert {:error, :plugin_conflict} =
             Artifact.validate(package, %{"other_owner" => other}, "artifact_fixture", nil)
  end

  test "firmware inventory discovers only entry points and opens immutable code without storage",
       %{artifact: artifact, tmp_dir: dir} do
    root = Path.join(dir, "firmware")
    path = Path.join([root, "artifact_fixture", "1.0.0"])
    File.mkdir_p!(Path.dirname(path))
    File.cp_r!(artifact.root, path)
    descriptor = Artifact.descriptor(%{artifact | source: :firmware})

    entry = %{
      enabled: false,
      active_version: "1.0.0",
      previous_version: nil,
      generation: 0,
      artifacts: %{"1.0.0" => descriptor}
    }

    :ok = Metadata.persist(Path.join(root, "inventory.term"), %{"artifact_fixture" => entry})
    previous = Application.get_env(:nerves_gate, :plugins_directory)
    Application.put_env(:nerves_gate, :plugins_directory, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, :plugins_directory, previous),
        else: Application.delete_env(:nerves_gate, :plugins_directory)
    end)

    assert {:ok, %{"artifact_fixture" => ^entry}} = Bundled.entries()
    assert Bundled.member?("artifact_fixture")
    assert Bundled.version("artifact_fixture") == "1.0.0"
    assert {:ok, %{source: :firmware}, _} = Artifact.load("artifact_fixture", "1.0.0", descriptor)

    assert {:error, :plugin_not_in_firmware} =
             Artifact.load("artifact_fixture", "2.0.0", descriptor)

    assert {:error, :plugin_not_in_firmware} = Artifact.load("missing", "1.0.0", descriptor)
    changed = put_in(entry.artifacts["1.0.0"].sha256, String.duplicate("f", 64))

    assert {:error, :firmware_artifact_conflict} =
             Bundled.merge(%{"artifact_fixture" => changed}, %{"artifact_fixture" => entry})

    old = %{entry | active_version: "0.9.0", artifacts: %{"0.9.0" => descriptor}}

    assert {:ok, merged} =
             Bundled.merge(%{"artifact_fixture" => old}, %{"artifact_fixture" => entry})

    assert merged["artifact_fixture"].active_version == "0.9.0"
    refute Bundled.selected?("artifact_fixture", merged["artifact_fixture"])
  end

  test "pure-BEAM policy rejects native payloads but permits ordinary priv data", %{
    package: package
  } do
    assert :ok = Package.pure_beam(package)

    for {name, bytes} <- [
          {"native.so", "binary"},
          {"hidden", <<127, "ELF", 0>>},
          {"script", "#!/bin/sh"}
        ] do
      assert {:error, :native_plugin_payload} =
               Package.pure_beam(%{
                 package
                 | files: Map.put(package.files, "artifact_fixture-1.0.0/priv/" <> name, bytes)
               })
    end

    assert :ok =
             Package.pure_beam(%{
               package
               | files: Map.put(package.files, "artifact_fixture-1.0.0/priv/registers.json", "{}")
             })
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

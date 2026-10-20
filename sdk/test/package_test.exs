defmodule NervesGateSDK.PackageTest do
  use ExUnit.Case, async: false
  alias NervesGateSDK.Package

  setup_all do
    [{module, beam}] =
      Code.compile_string("""
      defmodule NervesGatePackageFixture do
        use Application
        def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
      end
      """)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    %{fixture_module: module, beam: beam}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "nerves_gate_package_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "reads and extracts standard OTP layout without a custom manifest", context do
    archive = archive(context)
    assert {:ok, package} = Package.read(archive)
    assert {:ok, ^package} = Package.read_binary(File.read!(archive))
    assert package.app == :package_fixture
    assert package.version == "1.0.0"
    assert :ok = Package.validate(package, Package.installed(), "1.0.0")
    destination = Path.join(context.root, "install")
    assert :ok = Package.extract(package, destination)
    assert File.read!(Path.join(destination, "package_fixture-1.0.0/priv/example.txt")) == "data"
    assert {:error, :eexist} = Package.extract(package, destination)
    assert {:ok, ^package} = Package.read_directory(destination)
    File.ln_s!("/etc/passwd", Path.join(destination, "package_fixture-1.0.0/priv/link"))
    assert {:error, :invalid_package} = Package.read_directory(destination)
  end

  test "rejects incompatible SDK, missing dependencies and platform conflicts", context do
    assert {:ok, package} = context |> archive() |> Package.read()
    installed = Package.installed()
    assert {:error, :incompatible_sdk} = Package.validate(package, installed, "2.0.0")
    assert {:error, :missing_dependency} = Package.validate(package, %{}, "1.0.0")

    assert {:error, :application_conflict} =
             Package.validate(package, Map.put(installed, package.app, package.main), "1.0.0")

    assert {:error, :module_conflict} =
             Package.validate(package, Map.put(installed, :other, package.main), "1.0.0")
  end

  test "rejects traversal, absolute paths, duplicate entries and arbitrary files", context do
    for path <- ["../escape", "package_fixture-1.0.0/../escape", "C:\\escape"] do
      file = archive(context, extra: [{String.to_charlist(path), "bad"}])
      assert {:error, reason} = Package.read(file)
      assert reason in [:invalid_path, :invalid_files]
    end

    file = archive(context, extra: [{~c"package_fixture-1.0.0/priv/example.txt", "duplicate"}])
    assert {:error, :duplicate_path} = Package.read(file)
    file = archive(context, extra: [{~c"package_fixture-1.0.0/unexpected", "bad"}])
    assert {:error, :invalid_files} = Package.read(file)
  end

  test "checks exact versions of referenced platform libraries", context do
    file =
      archive(context,
        env: [nerves_gate_sdk_requirement: "~> 1.0", nerves_gate_platform: [jason: "1.4.5"]]
      )

    assert {:ok, package} = Package.read(file)
    installed = Map.put(Package.installed(), :jason, %{version: "1.4.4", modules: []})

    assert {:error, :incompatible_platform_dependency} =
             Package.validate(package, installed, "1.0.0")

    installed = put_in(installed.jason.version, "1.4.5")
    assert :ok = Package.validate(package, installed, "1.0.0")
  end

  test "rejects non-archive byte snapshots and non-files", context do
    assert {:error, _} = Package.read_binary("not a zip")
    assert {:error, :invalid_package} = Package.read_binary(nil)
    assert {:error, :invalid_package} = Package.read(context.root)
  end

  test "rejects missing SDK metadata and mislabeled beam modules", context do
    assert {:error, :invalid_package} = context |> archive(env: []) |> Package.read()
    assert {:error, :invalid_files} = context |> archive(module: OtherModule) |> Package.read()
  end

  defp archive(context, opts \\ []) do
    module = Keyword.get(opts, :module, context.fixture_module)

    spec =
      {:application, :package_fixture,
       [
         vsn: ~c"1.0.0",
         modules: [module],
         applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
         mod: {module, []},
         env: Keyword.get(opts, :env, nerves_gate_sdk_requirement: "~> 1.0")
       ]}

    files =
      [
        {~c"package_fixture-1.0.0/ebin/package_fixture.app",
         IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))},
        {String.to_charlist("package_fixture-1.0.0/ebin/#{module}.beam"), context.beam},
        {~c"package_fixture-1.0.0/priv/example.txt", "data"}
      ] ++ Keyword.get(opts, :extra, [])

    file = Path.join(context.root, "fixture.ez")
    {:ok, _} = :zip.create(String.to_charlist(file), files)
    file
  end
end

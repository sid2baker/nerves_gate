defmodule NervesGate.AppReleasesTest do
  use ExUnit.Case, async: false
  alias NervesGate.Apps.Releases
  alias NervesGateSDK.Package

  setup_all do
    [{module, beam}] =
      Code.compile_string("""
      defmodule AppReleaseFixture do
        use Application
        def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
      end
      """)

    spec =
      {:application, :tailnet_subrouter,
       [
         vsn: ~c"1.1.0",
         modules: [module],
         applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
         mod: {module, []},
         env: [nerves_gate_sdk_requirement: "~> 0.2.0-dev", nerves_gate_platform: []]
       ]}

    files = [
      {~c"tailnet_subrouter-1.1.0/ebin/tailnet_subrouter.app",
       IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))},
      {~c"tailnet_subrouter-1.1.0/ebin/Elixir.AppReleaseFixture.beam", beam}
    ]

    {:ok, {_, archive}} = :zip.create(~c"release.ez", files, [:memory])
    {:ok, package} = Package.read_binary(archive)
    {:ok, manifest} = Releases.describe(package, archive, String.duplicate("a", 40))

    on_exit(fn ->
      :code.delete(module)
      :code.soft_purge(module)
    end)

    %{archive: archive, package: package, manifest: manifest}
  end

  setup do
    previous = Application.fetch_env!(:nerves_gate, :target)
    Application.put_env(:nerves_gate, :target, :x86_64)
    on_exit(fn -> Application.put_env(:nerves_gate, :target, previous) end)
    :ok
  end

  test "catalog is limited to approved complete releases and picks semver, not creation order" do
    entry = fn version ->
      %{
        "tag_name" => Releases.tag("tailnet_subrouter", version),
        "draft" => false,
        "prerelease" => false,
        "assets" =>
          Enum.map(
            [
              Releases.archive("tailnet_subrouter", version),
              Releases.manifest_name("tailnet_subrouter", version)
            ],
            &%{"name" => &1, "state" => "uploaded"}
          )
      }
    end

    releases = [
      entry.("1.2.0"),
      entry.("1.10.0"),
      entry.("1.9.0"),
      %{"tag_name" => "v99.0.0"},
      %{entry.("99.0.0") | "draft" => true},
      %{entry.("98.0.0") | "assets" => []}
    ]

    assert [%{app: "tailnet_subrouter", version: "1.10.0"}] = Releases.latest(releases)
    assert {:ok, [_]} = Releases.available(plug: fn conn -> Req.Test.json(conn, releases) end)
  end

  test "metadata is current-only, bounded and bound to app/version/runtime", %{manifest: manifest} do
    assert :ok = Releases.validate(manifest, "tailnet_subrouter", "1.1.0")

    for changed <- [
          Map.put(manifest, "extra", true),
          %{manifest | "schema" => 0},
          %{manifest | "archive" => "../outside.ez"},
          %{manifest | "size" => 17 * 1024 * 1024},
          %{manifest | "source_revision" => "dirty"},
          %{manifest | "platform" => [["jason", "1.0.0"], ["jason", "1.0.0"]]}
        ] do
      assert {:error, :invalid_release_metadata} =
               Releases.validate(changed, "tailnet_subrouter", "1.1.0")
    end

    assert {:error, :invalid_release_metadata} = Releases.validate(manifest, "other", "1.1.0")
    assert {:error, :unknown_app_release} = Releases.review("other", "1.1.0")
    assert {:error, :unknown_app_release} = Releases.review("tailnet_subrouter", nil)
    assert :ok = Releases.compatible(manifest)

    assert {:error, :incompatible_release_runtime} =
             Releases.compatible(%{manifest | "otp" => "999"})

    assert {:error, :incompatible_sdk} = Releases.compatible(%{manifest | "sdk" => "~> 9.0"})

    assert {:error, :incompatible_platform_dependency} =
             Releases.compatible(%{manifest | "platform" => [["jason", "99.0.0"]]})

    Application.put_env(:nerves_gate, :target, :host)
    assert {:error, :incompatible_release_target} = Releases.compatible(manifest)
  end

  test "review and archive transfer are bounded HTTP reads; hash/package identity must match", %{
    archive: bytes,
    manifest: manifest
  } do
    parent = self()

    plug = fn conn ->
      send(parent, {:read, conn.method, conn.host, conn.request_path})

      body =
        if String.ends_with?(conn.request_path, ".json"), do: Jason.encode!(manifest), else: bytes

      Plug.Conn.send_resp(conn, 200, body)
    end

    assert {:ok, ^manifest} = Releases.review("tailnet_subrouter", "1.1.0", plug: plug)
    assert {:ok, %{app: :tailnet_subrouter}, ^bytes, _} = Releases.download(manifest, plug: plug)
    assert_receive {:read, "GET", "github.com", _}
    corrupt = fn conn -> Plug.Conn.send_resp(conn, 200, bytes <> "corrupt") end
    assert {:error, _} = Releases.download(manifest, plug: corrupt)

    assert {:error, :release_integrity_failed} =
             Releases.download(%{manifest | "sha256" => String.duplicate("b", 64)}, plug: plug)

    assert {:error, :release_fetch_failed} =
             Releases.review("tailnet_subrouter", "1.1.0",
               plug: fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("a", 70_000)) end
             )
  end

  @tag :tmp_dir
  test "transfer does not reject an installed previous version before the lifecycle can validate ownership",
       %{tmp_dir: dir, package: package, manifest: manifest, archive: bytes} do
    old = {:application, :tailnet_subrouter, Keyword.put(package.main.spec, :vsn, ~c"1.0.0")}

    File.write!(
      Path.join(dir, "tailnet_subrouter.app"),
      IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [old]))
    )

    true = :code.add_patha(String.to_charlist(dir))

    try do
      assert {:error, :application_conflict} =
               Package.validate(package, Package.installed(), "0.2.0-dev")

      assert {:ok, _, ^bytes, _} =
               Releases.download(manifest,
                 plug: fn conn -> Plug.Conn.send_resp(conn, 200, bytes) end
               )
    after
      :code.del_path(String.to_charlist(dir))
    end
  end

  test "never follows an untrusted redirect or retries provider errors" do
    parent = self()

    plug = fn conn ->
      send(parent, :requested)

      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/private")
      |> Plug.Conn.send_resp(302, "")
    end

    assert {:error, :release_fetch_failed} = Releases.available(plug: plug)
    assert_receive :requested
    refute_receive :requested

    for status <- [403, 429, 500, 404] do
      assert {:error, _} =
               Releases.available(
                 plug: fn conn ->
                   send(parent, :provider)
                   Plug.Conn.send_resp(conn, status, "failure")
                 end
               )

      assert_receive :provider
      refute_receive :provider
    end

    for url <- [
          "http://github.com/",
          "https://github.com.evil.test/",
          "https://user@github.com/",
          "https://github.com:444/",
          "https://localhost/"
        ] do
      refute Releases.allowed_url?(url)
    end

    assert Releases.allowed_url?(
             "https://release-assets.githubusercontent.com/github-production-release-asset/one"
           )
  end

  test "release preparation rejects private/native payloads", %{package: package, archive: bytes} do
    changed = %{
      package
      | files:
          Map.put(package.files, "tailnet_subrouter-1.1.0/priv/native.so", <<127, 69, 76, 70>>)
    }

    assert {:error, :unsupported_release_payload} =
             Releases.describe(changed, bytes, String.duplicate("a", 40))
  end
end

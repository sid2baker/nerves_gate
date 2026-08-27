defmodule NervesGate.Firmware.ArtifactTest.FlakyHTTP do
  def download(_url, path, expected_size, progress, _options) do
    File.mkdir_p!(Path.dirname(path))
    attempt = Process.get(:artifact_download_attempt, 0)
    Process.put(:artifact_download_attempt, attempt + 1)

    if attempt == 0 do
      bytes = div(expected_size, 2)
      File.write!(path, :binary.copy(<<0>>, bytes))
      progress.(bytes)
      {:error, {:http, :closed}}
    else
      existing = File.stat!(path).size
      File.write!(path, :binary.copy(<<0>>, expected_size - existing), [:append])
      progress.(expected_size)
      {:ok, expected_size}
    end
  end
end

defmodule NervesGate.Firmware.ArtifactTest do
  use ExUnit.Case, async: true

  alias NervesGate.Firmware.{Artifact, Release}
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:firmware_artifact)
    path = Path.join(root, "candidate.fw")
    File.mkdir_p!(root)
    File.write!(path, "signed firmware")
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: path}
  end

  test "resumes a bounded transient download before promoting the artifact", %{path: path} do
    release = %{release(path) | size: 1024}
    progress = fn bytes -> send(self(), {:progress, bytes}) end

    assert {:ok, downloaded} =
             Artifact.download(release, Path.dirname(path), progress,
               http: NervesGate.Firmware.ArtifactTest.FlakyHTTP
             )

    assert File.stat!(downloaded).size == release.size
    assert_receive {:progress, 512}
    assert_receive {:progress, 1024}
    refute File.exists?(Artifact.partial_path(Path.dirname(path), release))
  end

  test "requires digest, fwup signature, and exact metadata before accepting", %{path: path} do
    release = release(path)

    runner = fn
      "fwup", ["-V" | _args], _options -> {"", 0}
      "fwup", ["-m" | _args], _options -> {metadata(release), 0}
    end

    assert {:ok, metadata} =
             Artifact.verify(path, release, current(),
               fwup_public_keys: ["trusted-key"],
               runner: runner
             )

    assert metadata["uuid"] == release.uuid
  end

  test "retries a transient verifier port crash", %{path: path} do
    release = release(path)
    attempts = :atomics.new(1, signed: false)

    runner = fn
      "fwup", ["-V" | _args], _options ->
        if :atomics.add_get(attempts, 1, 1) == 1,
          do: Process.exit(self(), :port_setup_failed),
          else: {"", 0}

      "fwup", ["-m" | _args], _options ->
        {metadata(release), 0}
    end

    assert {:ok, _metadata} =
             Artifact.verify(path, release, current(),
               fwup_public_keys: ["trusted-key"],
               runner: runner
             )

    assert :atomics.get(attempts, 1) == 2
  end

  test "rejects corrupt content before invoking fwup", %{path: path} do
    release = %{release(path) | sha256: String.duplicate("0", 64)}

    runner = fn _command, _arguments, _options -> flunk("fwup must not run") end

    assert {:error, :artifact_digest_mismatch} =
             Artifact.verify(path, release, current(),
               fwup_public_keys: ["trusted-key"],
               runner: runner
             )
  end

  test "rejects invalid signatures and wrong firmware metadata", %{path: path} do
    release = release(path)

    assert {:error, :invalid_firmware_signature} =
             Artifact.verify(path, release, current(),
               fwup_public_keys: ["trusted-key"],
               runner: fn _command, _arguments, _options -> {"invalid", 1} end
             )

    runner = fn
      "fwup", ["-V" | _args], _options -> {"", 0}
      "fwup", ["-m" | _args], _options -> {metadata(%{release | system: "wrong"}), 0}
    end

    assert {:error, :firmware_metadata_mismatch} =
             Artifact.verify(path, release, current(),
               fwup_public_keys: ["trusted-key"],
               runner: runner
             )
  end

  defp release(path) do
    %Release{
      id: "candidate",
      version: "2.0.0",
      uuid: "candidate",
      product: "nerves_gate",
      system: "nerves_system_nerves_gate",
      platform: "x86_64",
      architecture: "x86_64",
      vcs_identifier: "new-revision",
      artifact: "nerves_gate.fw",
      asset_url: "https://example.invalid/nerves_gate.fw",
      size: File.stat!(path).size,
      sha256:
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    }
  end

  defp current do
    %{
      product: "nerves_gate",
      system: "nerves_system_nerves_gate",
      platform: "x86_64",
      architecture: "x86_64",
      version: "1.0.0",
      uuid: "old"
    }
  end

  defp metadata(release) do
    """
    meta-product=#{release.product}
    meta-version=#{release.version}
    meta-platform=#{release.platform}
    meta-architecture=#{release.architecture}
    meta-misc=#{release.system}
    meta-vcs-identifier=#{release.vcs_identifier}
    meta-uuid=#{release.uuid}
    """
  end
end

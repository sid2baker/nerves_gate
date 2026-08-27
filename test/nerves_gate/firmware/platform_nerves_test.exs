defmodule NervesGate.Firmware.Platform.NervesTest do
  use ExUnit.Case, async: true

  alias NervesGate.Firmware.Platform.Nerves
  alias NervesGate.Firmware.Release

  test "retries a contained installer port crash" do
    attempts = :atomics.new(1, signed: false)

    runner = fn _executable, _arguments, _options ->
      if :atomics.add_get(attempts, 1, 1) == 1,
        do: Process.exit(self(), :port_setup_failed),
        else: {"", 0}
    end

    assert :ok =
             Nerves.install_verified("/data/firmware/candidate.fw", release(),
               runner: runner,
               fwup_public_keys: ["trusted"]
             )

    assert :atomics.get(attempts, 1) == 2
  end

  defp release do
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
      size: 1024,
      sha256: String.duplicate("0", 64)
    }
  end
end

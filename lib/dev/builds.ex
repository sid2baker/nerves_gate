defmodule Dev.Builds do
  @moduledoc "Explicit isolated firmware builds using the standard Nerves task."
  def firmware!(report \\ fn _ -> :ok end) do
    status =
      NervesGateSim.Simulator.BuildOutput.run(
        "mix",
        ["firmware", "--overwrite"],
        [
          cd: Path.join(Dev.root(), "firmware"),
          env: [
            {"MIX_TARGET", "x86_64"},
            {"MIX_ENV", "dev"},
            {"NERVES_GATE_LOCAL_DEPS", "1"},
            {"NERVES_GATE_DEVICE_NODE", nil}
          ]
        ],
        report
      )

    if status != 0, do: raise("Firmware build failed (exit #{status})")
    Path.join(Dev.root(), "firmware/_build/x86_64_dev/nerves/images/nerves_gate.fw")
  end
end

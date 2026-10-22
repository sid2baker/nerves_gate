defmodule Dev.Builds do
  @moduledoc "Explicit isolated firmware builds using the standard Nerves task."
  def firmware!(target \\ "x86_64", report \\ fn _ -> :ok end)
      when target in ["ec100", "x86_64"] do
    status =
      NervesGateSim.Simulator.BuildOutput.run(
        "mix",
        ["firmware", "--overwrite"],
        [
          cd: Path.join(Dev.root(), "firmware"),
          env: [
            {"MIX_TARGET", target},
            {"MIX_ENV", "dev"},
            {"NERVES_GATE_LOCAL_DEPS", "1"},
            {"NERVES_GATE_DEVICE_NODE", nil}
          ]
        ],
        report
      )

    if status != 0,
      do:
        raise(
          "Firmware build failed (exit #{status}); inspect build output and system artifact availability"
        )

    Path.join(Dev.root(), "firmware/_build/#{target}_dev/nerves/images/nerves_gate.fw")
  end
end

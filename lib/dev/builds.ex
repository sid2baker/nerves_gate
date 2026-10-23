defmodule Dev.Builds do
  @moduledoc "Explicit isolated firmware builds and local image selection."

  def images(root \\ Dev.root()) do
    Path.wildcard(Path.join(root, "firmware/_build/ec100_*/nerves/images/*.fw"))
    |> Enum.flat_map(fn path ->
      # Keep metadata inspection bounded without MuonTrap's captured-stdio ACK path.
      case System.cmd("timeout", ["5s", "fwup", "-m", "-i", path], stderr_to_stdout: true) do
        {text, 0} ->
          metadata = Dev.FirmwareUpdate.metadata(text)

          if metadata["meta-product"] == "nerves_gate" and
               metadata["meta-platform"] == "ec100" and
               metadata["meta-architecture"] == "arm" and is_binary(metadata["meta-version"]) do
            [
              %{
                path: path,
                version: metadata["meta-version"],
                build: Path.relative_to(path, root)
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  def firmware!(target \\ "x86_64", report \\ fn _ -> :ok end)
      when target in ["ec100", "x86_64"] do
    status =
      Simulator.BuildOutput.run(
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

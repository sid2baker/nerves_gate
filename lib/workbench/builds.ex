defmodule Workbench.Builds do
  @moduledoc "Explicit isolated firmware builds and local image selection."

  # Physical boards. x86_64 is the QEMU simulator: buildable, but never
  # provisioned or updated through the physical image lists.
  @physical ["ec100", "em300"]

  def physical_targets, do: @physical

  @doc "Whether `firmware!/3` builds this target and environment."
  def buildable?(target, env),
    do: (target == "x86_64" and env == :dev) or (target in @physical and env in [:dev, :prod])

  def images(root \\ Workbench.root()) do
    Path.wildcard(Path.join(root, "firmware/_build/*/nerves/images/*.fw"))
    |> Enum.flat_map(fn path ->
      build = path |> Path.relative_to(root) |> Path.split() |> Enum.at(2)

      # Keep metadata inspection bounded without MuonTrap's captured-stdio ACK path.
      case System.cmd("timeout", ["5s", "fwup", "-m", "-i", path], stderr_to_stdout: true) do
        {text, 0} ->
          metadata = Workbench.FirmwareUpdate.metadata(text)
          target = metadata["meta-platform"]

          # A physical board's archive, in that board's own build directory.
          if target in @physical and String.starts_with?(build, target <> "_") and
               metadata["meta-product"] == "nerves_gate" and
               metadata["meta-architecture"] == "arm" and is_binary(metadata["meta-version"]) do
            [
              %{
                path: path,
                target: target,
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

  def assets!(report \\ fn _ -> :ok end) do
    Workbench.BuildLock.run!(fn ->
      report.("Building frontend assets")

      case Volt.build() do
        {:ok, _result} -> :ok
        {:error, reason} -> raise "Asset build failed: #{inspect(reason)}"
      end
    end)
  end

  def firmware!(target \\ "x86_64", report \\ fn _ -> :ok end, env \\ :dev) do
    unless buildable?(target, env),
      do:
        raise(
          ArgumentError,
          "Build x86_64 (dev) or a physical board: #{Enum.join(@physical, ", ")}"
        )

    Workbench.BuildLock.run!(fn ->
      assets!(report)
      Workbench.PluginBuild.build!(report)

      status =
        Simulator.BuildOutput.run(
          "mix",
          ["firmware", "--overwrite"],
          [
            cd: Path.join(Workbench.root(), "firmware"),
            env: [
              {"MIX_TARGET", target},
              {"MIX_ENV", Atom.to_string(env)},
              {"NERVES_GATE_LOCAL_DEPS", "1"},
              {"NERVES_GATE_DEVICE_NODE", nil}
            ]
          ],
          report
        )

      if status != 0 do
        raise "Firmware build failed (exit #{status}); inspect build output and system artifact availability"
      end

      Path.join(Workbench.root(), "firmware/_build/#{target}_#{env}/nerves/images/nerves_gate.fw")
    end)
  end
end

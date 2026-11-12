defmodule Workbench.Builds do
  @moduledoc "Explicit isolated firmware builds and local image selection."

  # One catalogue for build admission, physical image selection and the picker.
  @targets [
    %{id: "x86_64", label: "x86_64 · simulated QEMU", physical: false},
    %{id: "ec100", label: "EC100 · physical hardware", physical: true},
    %{id: "em300", label: "EM300 · physical hardware (SPI NAND)", physical: true}
  ]

  def targets, do: @targets
  def physical_targets, do: for(%{id: id, physical: true} <- @targets, do: id)

  @doc "Whether `firmware!/3` builds this target and environment."
  def buildable?(target, env) do
    Enum.any?(@targets, &(&1.id == target and (env == :dev or (&1.physical and env == :prod))))
  end

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
          if target in physical_targets() and String.starts_with?(build, target <> "_") and
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

  @doc """
  Environment of an isolated target Mix process. Everything that inspects a
  build (such as factory boot artifacts) uses it, so it resolves the same system.
  """
  def target_env(target, env) do
    [
      {"MIX_TARGET", target},
      {"MIX_ENV", to_string(env)},
      {"NERVES_GATE_SIMULATOR_SYSTEM_PATH", System.get_env("NERVES_GATE_SIMULATOR_SYSTEM_PATH")},
      {"NERVES_GATE_EC100_SYSTEM_PATH", System.get_env("NERVES_GATE_EC100_SYSTEM_PATH")},
      {"NERVES_GATE_EM300_SYSTEM_PATH", System.get_env("NERVES_GATE_EM300_SYSTEM_PATH")},
      {"NERVES_SYSTEM", nil},
      {"NERVES_GATE_DEVICE_NODE", nil}
    ]
  end

  def firmware!(target \\ "x86_64", report \\ fn _ -> :ok end, env \\ :dev) do
    unless buildable?(target, env),
      do:
        raise(
          ArgumentError,
          "Build x86_64 (dev) or a physical board: #{Enum.join(physical_targets(), ", ")}"
        )

    Workbench.BuildLock.run!(fn ->
      assets!(report)
      Workbench.PluginBuild.build!(target, report, env)

      status =
        Simulator.BuildOutput.run(
          "mix",
          ["firmware", "--overwrite"],
          [cd: Path.join(Workbench.root(), "firmware"), env: target_env(target, env)],
          report
        )

      if status != 0 do
        raise "Firmware build failed (exit #{status}); inspect build output and system artifact availability"
      end

      Path.join(Workbench.root(), "firmware/_build/#{target}_#{env}/nerves/images/nerves_gate.fw")
    end)
  end
end

defmodule Workbench.PluginBuild do
  @moduledoc "Host-only assembly of the explicitly selected pure-BEAM firmware plugins."
  alias NervesGate.Plugins.{Artifact, Metadata}
  alias NervesGateSDK.Package

  def build!(report \\ fn _ -> :ok end) do
    root = Workbench.root()
    projects = Code.eval_file(Path.join(root, "plugins/selection.exs")) |> elem(0)
    destination = Path.join(root, "firmware/priv/plugins")
    stage = destination <> ".#{Base.encode16(:crypto.strong_rand_bytes(8))}"
    File.mkdir_p!(stage)

    try do
      entries =
        Enum.reduce(projects, %{}, fn project, entries ->
          output = Workbench.Applications.package!(Path.expand(project, root), report, :temporary)

          try do
            add!(output, stage, entries)
          after
            File.rm(output)
          end
        end)

      :ok = Metadata.persist(Path.join(stage, "inventory.term"), entries)
      # This is generated host build output, never a live device artifact root.
      Artifact.remove_stage(destination)
      File.rename!(stage, destination)
      report.("Bundled plugins: #{Enum.join(Enum.sort(Map.keys(entries)), ", ")}")
      destination
    after
      Artifact.remove_stage(stage)
    end
  end

  def add!(archive, root, entries) do
    {:ok, package, bytes, sha} = Artifact.read(archive)
    app = to_string(package.app)
    if Map.has_key?(entries, app), do: raise("Duplicate plugin selection: #{app}")

    case Artifact.validate(package, entries, app, nil) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Plugin #{app} rejected: #{inspect(reason)}; already selected: #{Enum.join(Enum.sort(Map.keys(entries)), ", ")}. Dependencies have one global namespace; share a compatible library through firmware explicitly."
    end

    destination = Path.join([root, app, package.version])
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "package.ez"), bytes, [:exclusive])
    :ok = Package.extract(package, Path.join(destination, "content"))
    artifact = Artifact.describe(package, sha, destination, bytes, :firmware)

    Map.put(entries, app, %{
      enabled: false,
      active_version: package.version,
      previous_version: nil,
      generation: 0,
      artifacts: %{package.version => Artifact.descriptor(artifact)}
    })
  end
end

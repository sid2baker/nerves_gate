defmodule NervesGate.Plugins.Bundled do
  @moduledoc "Build-generated firmware inventory. Dependencies are not plugin entry points."
  alias NervesGate.Plugins.{Artifact, Metadata}

  def root do
    Application.get_env(
      :nerves_gate,
      :plugins_directory,
      Path.join(to_string(:code.priv_dir(:nerves_gate)), "plugins")
    )
  end

  def entries, do: Metadata.read(Path.join(root(), "inventory.term"))

  def member?(app) do
    case entries() do
      {:ok, entries} -> Map.has_key?(entries, app)
      _ -> false
    end
  end

  def version(app) do
    case entries() do
      {:ok, entries} -> get_in(entries, [app, :active_version])
      _ -> nil
    end
  end

  def selected?(app, entry) do
    case entries() do
      {:ok, entries} ->
        get_in(entries, [app, :artifacts, entry.active_version]) ==
          entry.artifacts[entry.active_version]

      _ ->
        false
    end
  end

  def load(app, version, metadata) do
    with {:ok, entries} <- entries(),
         %{artifacts: artifacts} <- entries[app],
         ^metadata <- artifacts[version] do
      Artifact.open(Path.join([root(), app, version]), app, version, metadata)
    else
      _ -> {:error, :plugin_not_in_firmware}
    end
  end

  def merge(saved, bundled) do
    conflict? =
      Enum.any?(bundled, fn {app, entry} ->
        Enum.any?(entry.artifacts, fn {version, artifact} ->
          existing = get_in(saved, [app, :artifacts, version])
          existing != nil and existing != artifact
        end)
      end)

    if conflict? do
      {:error, :firmware_artifact_conflict}
    else
      {:ok,
       Map.merge(saved, bundled, fn _app, saved, bundled ->
         %{saved | artifacts: Map.merge(saved.artifacts, bundled.artifacts)}
       end)}
    end
  end
end

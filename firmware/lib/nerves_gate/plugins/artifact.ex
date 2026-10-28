defmodule NervesGate.Plugins.Artifact do
  @moduledoc "Immutable application archive identity and verified installed content."
  alias NervesGate.Storage
  alias NervesGateSDK.Package
  @enforce_keys [:app, :version, :sha256, :root, :apps, :modules, :paths, :manifest]
  defstruct @enforce_keys ++ [source: :development]

  def read(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 128 * 1024 * 1024 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, package} <- Package.read_binary(bytes),
         :ok <- Package.pure_beam(package) do
      {:ok, package, bytes, hash(bytes)}
    else
      _ -> {:error, :invalid_package}
    end
  end

  def review(
        package,
        sha,
        %{plugin: plugin, version: version, sha256: expected, card_id: card},
        entries
      )
      when is_binary(plugin) and is_binary(version) and is_binary(expected) and is_binary(card) do
    if to_string(package.app) == plugin and package.version == version and sha == expected and
         not Map.has_key?(entries, plugin), do: :ok, else: {:error, :review_changed}
  end

  def review(_, _, _, _), do: {:error, :invalid_review}

  def install(package, bytes, sha) do
    with {:ok, root} <- Storage.plugins_dir(),
         {:ok, parent} <- Storage.directory(root, to_string(package.app)) do
      destination = Path.join(parent, package.version)
      stage = Path.join(parent, ".install-#{Base.encode16(:crypto.strong_rand_bytes(16))}")
      install_at(package, bytes, sha, stage, destination)
    end
  end

  defp install_at(package, bytes, sha, stage, destination) do
    if File.exists?(destination) do
      {:error, :artifact_exists}
    else
      with :ok <- File.mkdir(stage) do
        try do
          stage_package(package, bytes, sha, stage, destination)
        after
          remove_stage(stage)
        end
      end
    end
  end

  defp stage_package(package, bytes, sha, stage, destination) do
    with :ok <- File.chmod(stage, 0o700),
         :ok <- File.write(Path.join(stage, "package.ez"), bytes, [:exclusive, :sync]),
         :ok <- Package.extract(package, Path.join(stage, "content")),
         :ok <- preserve_modes(bytes, Path.join(stage, "content")),
         :ok <- freeze(stage),
         false <- File.exists?(destination),
         :ok <- File.rename(stage, destination) do
      {:ok, describe(package, sha, destination, bytes)}
    else
      true -> {:error, :artifact_exists}
      error -> error
    end
  end

  def load(app, version, metadata) do
    if metadata.source == :firmware do
      NervesGate.Plugins.Bundled.load(app, version, metadata)
    else
      with {:ok, root} <- Storage.plugins_dir() do
        open(Path.join([root, app, version]), app, version, metadata)
      end
    end
  end

  @doc "Verify a registered artifact's exact identity and extracted tree. Performs no activation."
  def open(directory, app, version, metadata) do
    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, package, bytes, sha} <- read(Path.join(directory, "package.ez")),
         true <- sha == metadata.sha256,
         true <- to_string(package.app) == app and package.version == version,
         artifact = describe(package, sha, directory, bytes, metadata.source),
         true <- descriptor(artifact) == metadata,
         :ok <- verify_content(artifact) do
      {:ok, artifact, package}
    else
      _ -> {:error, :artifact_modified}
    end
  end

  def describe(package, sha, root, bytes, source \\ :development) do
    modes = modes(bytes)

    %__MODULE__{
      app: package.app,
      version: package.version,
      sha256: sha,
      root: root,
      source: source,
      apps: package.apps,
      modules: Enum.flat_map(package.apps, & &1.modules),
      paths: Enum.map(package.apps, &Path.join([root, "content", &1.root, "ebin"])),
      manifest:
        Map.new(package.files, fn {name, data} ->
          {name,
           %{sha256: hash(data), size: byte_size(data), executable: Map.get(modes, name, 0)}}
        end)
    }
  end

  def descriptor(artifact) do
    %{
      sha256: artifact.sha256,
      source: artifact.source,
      names: artifact.apps |> Enum.map(&to_string(&1.app)) |> Enum.sort(),
      modules: artifact.modules |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  def validate(package, entries, owner, previous) do
    own = if previous, do: Enum.map(previous.apps, & &1.app), else: []
    installed = Map.drop(Package.installed(), own)
    names = MapSet.new(Enum.map(package.apps, &to_string(&1.app)))

    modules =
      MapSet.new(Enum.flat_map(package.apps, fn app -> Enum.map(app.modules, &to_string/1) end))

    conflicts =
      for {app, entry} <- entries,
          app != owner,
          {_version, artifact} <- entry.artifacts,
          do: artifact

    with false <-
           Enum.any?(conflicts, &(overlap?(names, &1.names) or overlap?(modules, &1.modules))),
         :ok <-
           Package.validate(
             package,
             installed,
             to_string(Application.spec(:nerves_gate_sdk, :vsn))
           ),
         :ok <- loaded_conflicts(package, previous) do
      :ok
    else
      true -> {:error, :plugin_conflict}
      error -> error
    end
  end

  defp overlap?(set, names), do: Enum.any?(names, &MapSet.member?(set, &1))

  defp loaded_conflicts(package, previous) do
    names = if previous, do: Enum.map(previous.apps, & &1.app), else: []

    if Enum.any?(package.apps, &app_conflict?(&1, names, previous)),
      do: {:error, :module_conflict},
      else: :ok
  end

  defp app_conflict?(app, names, previous) do
    (Application.spec(app.app) != nil and app.app not in names) or
      Enum.any?(app.modules, &module_conflict?(&1, previous))
  end

  defp module_conflict?(module, previous) do
    case :code.is_loaded(module) do
      false -> :erlang.check_old_code(module)
      {:file, path} -> not (previous && owns_module?(previous, module, path))
    end
  end

  def owns_module?(artifact, module, path) when is_list(path) do
    module in artifact.modules and
      Enum.any?(artifact.paths, &(Path.join(&1, "#{module}.beam") == to_string(path)))
  end

  def owns_module?(_, _, _), do: false

  def beam(artifact, module, files) do
    app = Enum.find(artifact.apps, &(module in &1.modules))
    relative = "#{app.root}/ebin/#{module}.beam"
    {Path.join([artifact.root, "content", relative]), Map.fetch!(files, relative)}
  end

  defp verify_content(artifact) do
    root = Path.join(artifact.root, "content")

    with {:ok, actual} <- tree(root, ""),
         true <- MapSet.new(actual) == expected_tree(artifact.manifest),
         true <-
           Enum.all?(artifact.manifest, fn {name, expected} ->
             matches_file?(Path.join(root, name), expected)
           end) do
      :ok
    else
      _ -> {:error, :artifact_modified}
    end
  end

  defp expected_tree(manifest) do
    Enum.reduce(Map.keys(manifest), MapSet.new(), fn name, set ->
      set = MapSet.put(set, {name, :regular})
      directories(Path.dirname(name), set)
    end)
  end

  defp directories(".", set), do: set

  defp directories(path, set),
    do: directories(Path.dirname(path), MapSet.put(set, {path, :directory}))

  defp tree(root, relative) do
    case File.lstat(Path.join(root, relative)) do
      {:ok, %{type: :directory}} -> tree_directory(root, relative)
      {:ok, %{type: :regular}} -> {:ok, [{relative, :regular}]}
      _ -> {:error, :invalid_file_type}
    end
  end

  defp tree_directory(root, relative) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      initial = if relative == "", do: [], else: [{relative, :directory}]
      Enum.reduce_while(names, {:ok, initial}, &tree_child(root, relative, &1, &2))
    end
  end

  defp tree_child(root, relative, name, {:ok, acc}) do
    case tree(root, Path.join(relative, name)) do
      {:ok, paths} -> {:cont, {:ok, paths ++ acc}}
      error -> {:halt, error}
    end
  end

  defp matches_file?(path, expected) do
    with {:ok, %{type: :regular, size: size, mode: mode}} <- File.lstat(path),
         true <- size == expected.size and Bitwise.band(mode, 0o111) == expected.executable do
      context =
        Enum.reduce(
          File.stream!(path, 64 * 1024),
          :crypto.hash_init(:sha256),
          &:crypto.hash_update(&2, &1)
        )

      Base.encode16(:crypto.hash_final(context), case: :lower) == expected.sha256
    else
      _ -> false
    end
  rescue
    _ in [File.Error, ArgumentError, ErlangError] -> false
  end

  defp modes(bytes) do
    {:ok, table} = :zip.table(bytes)

    for {:zip_file, name, info, _, _, _} <- table,
        elem(info, 2) == :regular,
        into: %{},
        do: {to_string(name), Bitwise.band(elem(info, 7), 0o111)}
  end

  defp preserve_modes(bytes, content) do
    reduce(modes(bytes), fn {name, executable} ->
      File.chmod(Path.join(content, name), 0o444 + executable)
    end)
  end

  defp freeze(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> freeze_directory(path)
      {:ok, %{type: :regular, mode: mode}} -> File.chmod(path, 0o444 + Bitwise.band(mode, 0o111))
      _ -> {:error, :invalid_file_type}
    end
  end

  defp freeze_directory(path) do
    with {:ok, names} <- File.ls(path),
         :ok <- reduce(names, &freeze(Path.join(path, &1))),
         do: File.chmod(path, 0o555)
  end

  @doc false
  def remove_stage(path) do
    if File.exists?(path) do
      thaw(path)
      File.rm_rf(path)
    end

    :ok
  end

  defp thaw(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, names} -> Enum.each(names, &thaw(Path.join(path, &1)))
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp reduce(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

defmodule NervesGateSDK.Package do
  @moduledoc false
  # Shared by the packaging task and the device installer. This is an OTP zip
  # archive, not a second package format. Packages contain trusted BEAM code.
  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @max_bytes 128 * 1024 * 1024
  @max_entries 10_000
  @shared ~w(kernel stdlib compiler elixir logger crypto asn1 public_key ssl inets
    eex runtime_tools tools syntax_tools xmerl sasl os_mon ssh nerves_gate_sdk
    jason telemetry phoenix_pubsub phoenix phoenix_live_view phoenix_html phoenix_template
    plug plug_crypto mime websock websock_adapter castore req finch mint hpax nimble_pool nimble_options)a
  @common ~w(jason telemetry phoenix_pubsub phoenix phoenix_live_view phoenix_html phoenix_template
    plug plug_crypto mime websock websock_adapter castore req finch mint hpax nimble_pool nimble_options)a

  def shared_apps, do: @shared
  def common_apps, do: @common

  def valid_name?(name) when is_atom(name), do: valid_name?(Atom.to_string(name))
  def valid_name?(name) when is_binary(name), do: Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name)
  def valid_name?(_), do: false

  def valid_version?(version) when is_binary(version) do
    match?({:ok, _}, Version.parse(version)) and not String.contains?(version, ["/", "\\"])
  end

  def valid_version?(_), do: false

  def read(path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      read_binary(bytes)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_package}
    end
  end

  def read(_), do: {:error, :invalid_package}

  # Validate a single byte snapshot; callers can transfer exactly what was checked.
  def read_binary(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, table} <- :zip.table(bytes),
         :ok <- check_table(table),
         {:ok, entries} <- :zip.extract(bytes, [:memory]) do
      entries |> Map.new(fn {name, data} -> {to_string(name), data} end) |> inspect_files()
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_package}
    end
  rescue
    _ -> {:error, :invalid_package}
  end

  def read_binary(_), do: {:error, :invalid_package}

  def read_directory(path) do
    {files, _size} = read_tree(path, "", {%{}, 0})
    inspect_files(files)
  rescue
    _ -> {:error, :invalid_package}
  catch
    :invalid_package -> {:error, :invalid_package}
  end

  defp read_tree(root, relative, {files, size}) do
    path = Path.join(root, relative)

    case File.lstat!(path) do
      %{type: :directory} ->
        Enum.reduce(File.ls!(path), {files, size}, fn name, acc ->
          read_tree(root, Path.join(relative, name), acc)
        end)

      %{type: :regular, size: bytes}
      when size + bytes <= @max_bytes and map_size(files) < @max_entries ->
        {Map.put(files, relative, File.read!(path)), size + bytes}

      _ ->
        throw(:invalid_package)
    end
  end

  defp inspect_files(files) do
    with true <- Enum.all?(Map.keys(files), &safe_path?/1),
         {:ok, apps} <- applications(files),
         [main] <- Enum.filter(apps, &Keyword.has_key?(&1.env, :nerves_gate_sdk_requirement)),
         true <- valid_version?(main.version),
         {:ok, _} <- Version.parse_requirement(main.env[:nerves_gate_sdk_requirement]),
         true <- :nerves_gate_sdk in main.applications,
         {module, args} when is_atom(module) and is_list(args) <- main.spec[:mod],
         true <- module in main.modules,
         true <- valid_ui?(main),
         :ok <- check_files(files, apps),
         :ok <- unique_modules(apps) do
      {:ok, %{app: main.app, version: main.version, main: main, apps: apps, files: files}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_package}
    end
  end

  defp valid_ui?(main) do
    case Keyword.fetch(main.env, :nerves_gate_ui) do
      :error -> true
      {:ok, module} -> is_atom(module) and module in main.modules
    end
  end

  # Snapshot before adding application paths. Includes platform and other apps,
  # so neither an OTP application nor one of its modules may be shadowed.
  # Earlier code paths win, just as they do in the VM's code server.
  def installed do
    for path <- Enum.reverse(:code.get_path()),
        file <- Path.wildcard(Path.join(to_string(path), "*.app")),
        {:ok, [spec]} = :file.consult(String.to_charlist(file)),
        {:ok, app} = application(spec),
        into: %{},
        do: {app.app, app}
  end

  def validate(package, installed, sdk_version) do
    names = MapSet.new(package.apps, & &1.app)
    modules = MapSet.new(Enum.flat_map(Map.values(installed), & &1.modules))

    cond do
      not Version.match?(sdk_version, package.main.env[:nerves_gate_sdk_requirement]) ->
        {:error, :incompatible_sdk}

      not compatible_platform?(package.main.env[:nerves_gate_platform] || [], installed) ->
        {:error, :incompatible_platform_dependency}

      Enum.any?(
        package.apps,
        &(&1.app in (@shared ++
                       [
                         :nerves_gate,
                         :nerves_gate_sim,
                         :nerves_gate_new,
                         :nerves_gate_dev,
                         :nerves_gate_workbench
                       ]) or
              Map.has_key?(installed, &1.app))
      ) ->
        {:error, :application_conflict}

      Enum.any?(package.apps, fn app -> Enum.any?(app.modules, &MapSet.member?(modules, &1)) end) ->
        {:error, :module_conflict}

      Enum.any?(package.apps, fn app ->
        Enum.any?(
          app.applications,
          &(not Map.has_key?(installed, &1) and not MapSet.member?(names, &1))
        )
      end) ->
        {:error, :missing_dependency}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :invalid_package}
  end

  defp compatible_platform?(requirements, installed) do
    Keyword.keyword?(requirements) and
      Enum.all?(requirements, fn {app, version} ->
        is_binary(version) and match?(%{version: ^version}, installed[app])
      end)
  end

  # Only validated relative regular files reach this function. Never extract a
  # zip directly over an existing application or follow archive symlinks.
  def extract(package, destination) do
    case File.mkdir(destination) do
      :ok ->
        result =
          Enum.reduce_while(package.files, :ok, fn {name, bytes}, :ok ->
            path = Path.join(destination, name)

            with :ok <- File.mkdir_p(Path.dirname(path)),
                 :ok <- File.write(path, bytes, [:binary, :exclusive]) do
              {:cont, :ok}
            else
              error -> {:halt, error}
            end
          end)

        if result != :ok, do: File.rm_rf(destination)
        result

      error ->
        error
    end
  end

  defp check_table(table) do
    entries = for zip_file() = entry <- table, do: entry
    names = Enum.map(entries, &to_string(zip_file(&1, :name)))

    cond do
      length(entries) > @max_entries ->
        {:error, :package_too_large}

      length(Enum.uniq(names)) != length(names) ->
        {:error, :duplicate_path}

      Enum.any?(entries, &(file_info(zip_file(&1, :info), :type) not in [:regular, :directory])) ->
        {:error, :invalid_file_type}

      Enum.any?(names, &(not safe_path?(&1))) ->
        {:error, :invalid_path}

      Enum.reduce(entries, 0, &(file_info(zip_file(&1, :info), :size) + &2)) > @max_bytes ->
        {:error, :package_too_large}

      true ->
        :ok
    end
  end

  defp safe_path?(name) do
    String.valid?(name) and not String.contains?(name, ["\\", ":", <<0>>]) and
      Path.type(name) == :relative and
      Enum.all?(String.split(String.trim_trailing(name, "/"), "/"), &(&1 not in ["", ".", ".."]))
  end

  defp applications(files) do
    specs = for {path, bytes} <- files, Path.extname(path) == ".app", do: {path, bytes}

    Enum.reduce_while(specs, {:ok, []}, fn {path, bytes}, {:ok, apps} ->
      with {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(bytes)),
           {:ok, term} <- :erl_parse.parse_term(tokens),
           {:ok, app} <- application(term),
           root = "#{app.app}-#{app.version}",
           true <- path == "#{root}/ebin/#{app.app}.app",
           false <- Enum.any?(apps, &(&1.app == app.app)) do
        {:cont, {:ok, [Map.put(app, :root, root) | apps]}}
      else
        _ -> {:halt, {:error, :invalid_application}}
      end
    end)
  end

  defp application({:application, app, spec}) when is_atom(app) and is_list(spec) do
    modules = spec[:modules]
    applications = (spec[:applications] || []) ++ (spec[:included_applications] || [])
    env = spec[:env] || []
    version = to_string(spec[:vsn])

    if valid_name?(app) and version != "" and is_list(modules) and
         Enum.all?(modules, &is_atom/1) and length(Enum.uniq(modules)) == length(modules) and
         is_list(applications) and Enum.all?(applications, &is_atom/1) and Keyword.keyword?(env) do
      {:ok,
       %{
         app: app,
         version: version,
         modules: modules,
         applications: applications,
         env: env,
         spec: spec
       }}
    else
      {:error, :invalid_application}
    end
  end

  defp application(_), do: {:error, :invalid_application}

  defp check_files(files, apps) do
    expected = for app <- apps, module <- app.modules, do: "#{app.root}/ebin/#{module}.beam"
    actual = for {path, _} <- files, Path.extname(path) == ".beam", do: path

    if Enum.sort(expected) == Enum.sort(actual) and
         Enum.all?(files, fn {path, bytes} -> valid_file?(path, bytes, apps) end),
       do: :ok,
       else: {:error, :invalid_files}
  end

  defp valid_file?(path, bytes, apps) do
    case String.split(path, "/", parts: 3) do
      [root, "priv", _] ->
        Enum.any?(apps, &(&1.root == root))

      [root, "ebin", name] ->
        Enum.any?(apps, fn app ->
          app.root == root and
            (name == "#{app.app}.app" or
               Enum.any?(app.modules, fn module ->
                 name == "#{module}.beam" and
                   match?({:ok, {^module, _}}, :beam_lib.chunks(bytes, [:exports]))
               end))
        end)

      _ ->
        false
    end
  end

  defp unique_modules(apps) do
    modules = Enum.flat_map(apps, & &1.modules)
    if length(Enum.uniq(modules)) == length(modules), do: :ok, else: {:error, :module_conflict}
  end
end

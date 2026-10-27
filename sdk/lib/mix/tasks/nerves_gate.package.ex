defmodule Mix.Tasks.NervesGate.Package do
  use Mix.Task

  @shortdoc "Package a trusted Nerves Gate application as a standard OTP .ez archive"
  @moduledoc """
  Compiles in production mode and writes `<app>-<version>.ez` in the current
  directory, or to `--output path`. Set `:nerves_gate_sdk_requirement` in the
  application's OTP `:env`.

  Private runtime dependencies are included as ordinary OTP application
  directories. OTP, Elixir, the SDK and common platform libraries are not bundled.
  The installer checks dependencies and module conflicts against the running
  platform. Plugins must be pure BEAM: contributed native runtime payloads and
  direct NIF loaders are rejected. Ordinary priv data is allowed.
  """
  @preferred_cli_env :prod

  alias NervesGateSDK.Package

  @impl true
  def run(args) do
    output =
      case OptionParser.parse(args, strict: [output: :string], aliases: [o: :output]) do
        {options, [], []} -> options[:output]
        _ -> Mix.raise("Usage: mix nerves_gate.package [--output path.ez]")
      end

    if Mix.env() == :prod do
      package(output)
    else
      # Mix discovers dependency tasks after choosing its initial environment
      # on a clean checkout. Re-enter natively to always build production code.
      app = Mix.Project.config()[:app]
      previous = Mix.env()
      project = Mix.Project.pop()
      conflicts = Code.get_compiler_option(:ignore_module_conflict)

      try do
        # Re-reading the same mix.exs is intentional, not a module conflict.
        Code.put_compiler_option(:ignore_module_conflict, true)
        Mix.env(:prod)

        Mix.Project.in_project(app, File.cwd!(), fn _ ->
          Mix.Task.clear()
          Mix.Task.run("loadconfig")
          package(output)
        end)
      after
        Code.put_compiler_option(:ignore_module_conflict, conflicts)
        Mix.env(previous)
        Mix.Project.push(project.name, project.file)
      end
    end
  end

  defp package(output) do
    Mix.Task.run("compile")
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)
    version = Keyword.fetch!(config, :version)
    installed = Package.installed()
    main = Map.fetch!(installed, app)
    validate_sdk_requirement!(config[:deps] || [], main.env[:nerves_gate_sdk_requirement])
    bundled = collect(app, installed, MapSet.new())
    platform = Map.drop(installed, MapSet.to_list(bundled))
    filename = Path.expand(output || "#{app}-#{version}.ez")

    if File.exists?(filename), do: Mix.raise("Refusing to overwrite #{filename}")

    files =
      for name <- Enum.sort(bundled),
          entry = Map.fetch!(installed, name),
          directory = name |> :code.lib_dir() |> to_string(),
          path <- Path.wildcard(Path.join(directory, "{ebin,priv}/**/*"), match_dot: true),
          File.regular?(path) do
        # Build priv symlinks are followed; the archive has regular files only.
        relative = Path.relative_to(path, directory)
        {String.to_charlist("#{name}-#{entry.version}/#{relative}"), File.read!(path)}
      end

    files = files ++ license_files(bundled, installed)

    if main.version != version,
      do: Mix.raise("Compiled application version does not match mix.exs")

    # Include transitive platform libraries: UI macros compile against Phoenix,
    # HTML and Plug as well as the app's direct LiveView dependency.
    requirements =
      for {name, entry} <- Enum.sort(platform),
          name in Package.common_apps(),
          do: {name, entry.version}

    env = Keyword.put(main.env, :nerves_gate_platform, requirements)
    spec = {:application, app, Keyword.put(main.spec, :env, env)}
    spec_path = String.to_charlist("#{app}-#{version}/ebin/#{app}.app")

    files =
      List.keyreplace(
        files,
        spec_path,
        0,
        {spec_path, IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))}
      )

    with {:ok, _} <- :zip.create(String.to_charlist(filename), files),
         {:ok, package} <- Package.read(filename),
         :ok <- Package.pure_beam(package),
         :ok <-
           Package.validate(package, platform, Map.fetch!(installed, :nerves_gate_sdk).version) do
      Mix.shell().info("Created #{Path.relative_to_cwd(filename)}")
    else
      {:error, reason} ->
        File.rm(filename)
        Mix.raise("Cannot package application: #{inspect(reason)}")
    end
  end

  defp license_files(bundled, installed) do
    sources = Mix.Project.deps_paths()

    for name <- Enum.sort(bundled),
        source = Map.get(sources, name, File.cwd!()),
        filename <- ["LICENSE", "LICENSE.md", "LICENSE.txt", "NOTICE", "NOTICE.md", "NOTICE.txt"],
        path = Path.join(source, filename),
        File.regular?(path) do
      entry = Map.fetch!(installed, name)
      {String.to_charlist("#{name}-#{entry.version}/priv/licenses/#{filename}"), File.read!(path)}
    end
  end

  @doc false
  def validate_sdk_requirement!(deps, declared) do
    requirement =
      Enum.find_value(deps, fn
        {:nerves_gate_sdk, requirement, _} when is_binary(requirement) -> requirement
        {:nerves_gate_sdk, requirement} when is_binary(requirement) -> requirement
        _ -> nil
      end)

    if requirement && requirement != declared,
      do: Mix.raise("The SDK dependency requirement must match :nerves_gate_sdk_requirement.")

    :ok
  end

  defp collect(app, installed, seen) do
    if MapSet.member?(seen, app) do
      seen
    else
      entry = Map.fetch!(installed, app)

      Enum.reduce(entry.applications, MapSet.put(seen, app), fn dependency, acc ->
        optional_missing =
          dependency in (entry.spec[:optional_applications] || []) and
            not Map.has_key?(installed, dependency)

        if dependency in Package.shared_apps() or otp?(dependency) or optional_missing,
          do: acc,
          else: collect(dependency, installed, acc)
      end)
    end
  end

  defp otp?(app) do
    case :code.lib_dir(app) do
      {:error, _} ->
        false

      path ->
        String.starts_with?(to_string(path), Path.join(to_string(:code.root_dir()), "lib") <> "/")
    end
  end
end

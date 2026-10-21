defmodule NervesGateNew.Workspace do
  @moduledoc "Commands used by generated app-development workspaces."

  def setup([]) do
    # Compiling the workspace prunes archive paths. Hex still needs its lazily
    # loaded modules while fetching dependencies for each independent app.
    Mix.Local.append_archives()
    for {name, path} <- apps(), do: in_app(name, path, Mix.env(), "deps.get", [])
  end

  def setup(_), do: Mix.raise("Usage: mix setup")

  def new([name]) do
    NervesGateNew.app(Path.join(root(), "apps"), name)
    Mix.shell().info("Run mix setup to fetch the new app's dependencies.")
  end

  def new(_), do: Mix.raise("Usage: mix app.new app_name")

  def sim(args) do
    config = Path.join(root(), "config/simulator.exs")
    {settings, _} = Code.eval_file(config)

    unless File.regular?(settings.firmware),
      do:
        Mix.raise(
          "Place a compatible x86_64 QEMU image at #{settings.firmware}, or edit config/simulator.exs"
        )

    Mix.Task.run("nerves_gate.sim", ["--config", config | args])
  end

  def test(args) do
    for {name, path} <- apps(), do: in_app(name, path, :test, "test", args)
  end

  def format(args) do
    for {name, path} <- apps(), do: in_app(name, path, Mix.env(), "format", args)
  end

  def package(args) do
    {{name, path}, args} = select(args)

    {options, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string], aliases: [o: :output])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix app.package [app] [--output file.ez]")

    output = options[:output] && Path.expand(options[:output])
    package_app(name, path, output || :release)
  end

  def install(args) do
    {{name, path}, args} = select(args)
    {options, rest, invalid} = OptionParser.parse(args, strict: [device: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix app.install [app] [--device device]")

    output = Path.join(root(), "_build/packages/#{name}-#{System.unique_integer([:positive])}.ez")
    package_app(name, path, output)
    device = if options[:device], do: [options[:device]], else: []

    try do
      Mix.Task.run("nerves_gate.sim.install", ["--package", output | device])
    after
      File.rm(output)
    end
  end

  defp package_app(name, path, output) do
    workspace = root()

    in_app(name, path, :prod, fn ->
      config = Mix.Project.config()

      output =
        if output == :release,
          do: Path.join(workspace, "packages/#{config[:app]}-#{config[:version]}.ez"),
          else: output

      File.mkdir_p!(Path.dirname(output))
      Mix.Task.run("nerves_gate.package", ["--output", output])
    end)
  end

  defp select([name | rest]) when not is_nil(name) do
    if String.starts_with?(name, "-") do
      {only_app!(), [name | rest]}
    else
      NervesGateNew.validate_name!(name)

      case List.keyfind(apps(), name, 0) do
        nil -> Mix.raise("Unknown app #{name}. Use mix app.new #{name} to create it.")
        app -> {app, rest}
      end
    end
  end

  defp select([]), do: {only_app!(), []}

  defp only_app! do
    case apps() do
      [app] -> app
      many -> Mix.raise("Choose an app: #{Enum.map_join(many, ", ", &elem(&1, 0))}")
    end
  end

  defp apps do
    root()
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(fn file ->
      path = Path.dirname(file)
      name = Path.basename(path)
      NervesGateNew.validate_name!(name)
      {name, path}
    end)
  end

  defp root, do: Mix.Project.project_file() |> Path.dirname() |> Path.expand()

  defp in_app(name, path, env, task, args),
    do: in_app(name, path, env, fn -> Mix.Task.run(task, args) end)

  # Independent projects, not umbrella children or shell-invoked Mix processes.
  # Restore paths, environment and compiler settings before returning to tools.
  defp in_app(name, path, env, run) do
    Mix.shell().info("==> #{name}")
    project = Mix.Project.pop()
    previous_env = Mix.env()
    previous_target = Mix.target()
    previous_os = System.get_env()
    paths = :code.get_path()
    compiler = Code.compiler_options()

    try do
      Mix.env(env)
      Mix.target(:host)
      Code.compiler_options(ignore_module_conflict: true)

      Mix.Project.in_project(String.to_atom(name), path, fn _ ->
        Mix.Task.clear()
        Mix.Task.run("loadconfig")
        run.()
      end)
    after
      Code.compiler_options(compiler)
      :code.set_path(paths)
      Mix.env(previous_env)
      Mix.target(previous_target)

      for key <- Map.keys(System.get_env()),
          not Map.has_key?(previous_os, key),
          do: System.delete_env(key)

      System.put_env(previous_os)
      Mix.Project.push(project.name, project.file)
    end
  end
end

defmodule Dev.Solution do
  @moduledoc "Separate solution repositories and their ordinary SDK applications."
  @reserved ~w(dev dev_web nerves_gate nerves_gate_dev nerves_gate_sdk nerves_gate_sim)

  def new!(path, local_sdk \\ false) do
    path = Path.expand(path)
    if File.exists?(path), do: raise(ArgumentError, "Refusing to overwrite #{path}")
    File.mkdir_p!(Path.join(path, "apps"))

    settings = %{
      platform: Dev.version(),
      firmware: :local,
      devices: %{gateway_a: %{network: %{internet: :lan1}}}
    }

    settings =
      if local_sdk,
        do: Map.put(settings, :sdk_source, Path.join(Dev.root(), "sdk")),
        else: settings

    File.write!(Path.join(path, "nerves_gate.exs"), [
      Code.format_string!(inspect(settings, limit: :infinity)),
      "\n"
    ])

    File.write!(
      Path.join(path, ".gitignore"),
      "/_build/\n/packages/\n/apps/*/deps/\n/apps/*/_build/\n"
    )

    File.write!(Path.join(path, ".formatter.exs"), "[inputs: [\"nerves_gate.exs\"]]\n")

    File.write!(
      Path.join(path, "README.md"),
      "# Solution\n\nOpen this directory from your Nerves Gate platform checkout with `mix dev #{path}`.\nApplications live in `apps/`; each is an independent Mix project.\n"
    )

    load!(path)
  end

  def load!(path) do
    path = Path.expand(path)
    {settings, _} = Code.eval_file(Path.join(path, "nerves_gate.exs"))

    unless is_map(settings) and is_binary(settings[:platform]) and is_map(settings[:devices]) and
             map_size(settings.devices) in 1..253 and
             (settings[:firmware] == :local or is_binary(settings[:firmware])),
           do: raise(ArgumentError, "Invalid solution configuration in #{path}/nerves_gate.exs")

    %{
      path: path,
      settings: settings,
      apps: apps(path),
      warning:
        if(settings.platform != Dev.version(),
          do: "Solution targets #{settings.platform}; checkout is #{Dev.version()}."
        )
    }
  end

  def current! do
    case System.get_env("NERVES_GATE_SOLUTION") do
      nil ->
        case Dev.Session.connect() do
          {_, %{"solution" => %{"path" => path}}} when is_binary(path) ->
            load!(path)

          _ ->
            raise ArgumentError,
                  "Supply --solution PATH or open a solution with mix dev PATH first"
        end

      path ->
        load!(path)
    end
  end

  def simulator_config!(solution, _dir), do: Path.join(solution.path, "nerves_gate.exs")

  def app_new!(solution, name) do
    validate_name!(name)
    if name in @reserved, do: raise(ArgumentError, "#{name} is a platform application name")
    path = Path.join([solution.path, "apps", name])
    if File.exists?(path), do: raise(ArgumentError, "Refusing to overwrite #{path}")
    source = solution.settings[:sdk_source] && Path.dirname(solution.settings.sdk_source)
    bindings = [app: name, module: Macro.camelize(name), source: source]
    templates = Path.join(Dev.root(), "priv/templates/app")

    for template <- Path.wildcard(Path.join(templates, "**/*"), match_dot: true),
        File.regular?(template) do
      relative =
        template
        |> Path.relative_to(templates)
        |> String.trim_trailing(".eex")
        |> String.replace("app_name", name)

      relative =
        case relative do
          "formatter.exs" -> ".formatter.exs"
          "gitignore" -> ".gitignore"
          other -> other
        end

      destination = Path.join(path, relative)
      File.mkdir_p!(Path.dirname(destination))
      contents = EEx.eval_file(template, bindings)

      contents =
        if Path.extname(destination) in [".ex", ".exs"],
          do: [Code.format_string!(contents), "\n"],
          else: contents

      File.write!(destination, contents)
    end

    path
  end

  def test!(solution, name \\ nil, report \\ fn _ -> :ok end) do
    selected = if name, do: [select!(solution, name)], else: apps(solution.path)

    if selected == [],
      do: raise(ArgumentError, "No apps; create one with mix app.new NAME --solution PATH")

    for {_, path} <- selected do
      run!(path, :test, ["deps.get"], report)
      run!(path, :test, ["test"], report)
    end

    :ok
  end

  def package!(solution, name \\ nil, report \\ fn _ -> :ok end, destination \\ :release) do
    {name, path} = select!(solution, name)

    relative =
      if destination == :temporary,
        do: "_build/packages/#{name}-#{Base.encode16(:crypto.strong_rand_bytes(8))}.ez",
        else: "packages/#{name}.ez"

    output = Path.join(solution.path, relative)
    File.mkdir_p!(Path.dirname(output))
    run!(path, :prod, ["deps.get"], report)
    run!(path, :prod, ["nerves_gate.package", "--output", output], report)
    output
  end

  def install!(solution, name, device, report \\ fn _ -> :ok end) do
    output = package!(solution, name, report, :temporary)

    try do
      case NervesGateSim.QemuTests.install(device, output) do
        {:ok, id} -> await_install!(id, report)
        {:error, message} -> raise ArgumentError, message
      end
    after
      File.rm(output)
    end
  end

  defp await_install!(id, report) do
    run =
      Enum.find(NervesGateSim.QemuTests.snapshot().runs, &(&1.id == id)) ||
        raise("Install outcome unknown; inspect the device page")

    report.(run.phase)

    case run.status do
      :running ->
        Process.sleep(250)
        await_install!(id, report)

      :passed ->
        :ok

      _ ->
        raise "Installation failed; inspect the device page"
    end
  end

  def select!(solution, nil) do
    case apps(solution.path) do
      [app] -> app
      apps -> raise ArgumentError, "Select an app: #{Enum.map_join(apps, ", ", &elem(&1, 0))}"
    end
  end

  def select!(solution, name) do
    validate_name!(name)
    List.keyfind(apps(solution.path), name, 0) || raise(ArgumentError, "Unknown app #{name}")
  end

  def validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
      do: raise(ArgumentError, "Names must contain lowercase letters, digits and underscores")
  end

  defp apps(path) do
    for file <- Path.wildcard(Path.join(path, "apps/*/mix.exs")) do
      dir = Path.dirname(file)
      name = Path.basename(dir)
      validate_name!(name)
      {name, dir}
    end
  end

  defp run!(path, env, args, report) do
    status =
      NervesGateSim.Simulator.BuildOutput.run(
        "mix",
        args,
        [
          cd: path,
          env: [
            {"MIX_TARGET", "host"},
            {"MIX_ENV", to_string(env)},
            {"NERVES_GATE_LOCAL_DEPS", nil},
            {"NERVES_GATE_DEVICE_NODE", nil}
          ]
        ],
        report
      )

    if status != 0, do: raise("mix #{Enum.join(args, " ")} failed (exit #{status})")
  end
end

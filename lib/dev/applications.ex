defmodule Dev.Applications do
  @moduledoc "Ordinary SDK application projects opened by the workbench."
  use GenServer
  @reserved ~w(dev dev_web nerves_gate nerves_gate_dev nerves_gate_sdk simulator)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def list, do: GenServer.call(__MODULE__, :list)
  def open(path), do: GenServer.call(__MODULE__, {:open, path})

  def init(_), do: {:ok, %{}}

  def handle_call(:list, _, state),
    do: {:reply, state |> Map.values() |> Enum.sort_by(& &1.path), state}

  def handle_call({:open, path}, _, state) do
    app = project!(path)
    {:reply, {:ok, app}, Map.put(state, app.path, app)}
  rescue
    error in [ArgumentError, File.Error] -> {:reply, {:error, Exception.message(error)}, state}
  end

  def project!(path) when is_binary(path) and path != "" do
    path = Path.expand(path)

    unless File.regular?(Path.join(path, "mix.exs")),
      do: raise(ArgumentError, "No Mix application at #{path}")

    if path == Dev.root(),
      do: raise(ArgumentError, "Open an application, not the platform project")

    %{path: path, name: Path.basename(path)}
  end

  def project!(_), do: raise(ArgumentError, "Supply the application directory")

  def new!(path, local_sdk \\ false) do
    path = Path.expand(path)
    name = Path.basename(path)
    validate_name!(name)
    if name in @reserved, do: raise(ArgumentError, "#{name} is a platform application name")
    if File.exists?(path), do: raise(ArgumentError, "Refusing to overwrite #{path}")
    bindings = [app: name, module: Macro.camelize(name), source: if(local_sdk, do: Dev.root())]
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

    project!(path)
  end

  def validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
      do: raise(ArgumentError, "Names must contain lowercase letters, digits and underscores")
  end

  def test!(path, report \\ fn _ -> :ok end) do
    app = project!(path)
    run!(app.path, :test, ["deps.get"], report)
    run!(app.path, :test, ["test"], report)
    :ok
  end

  def package!(path, report \\ fn _ -> :ok end, destination \\ :release) do
    app = project!(path)

    relative =
      if destination == :temporary,
        do: "_build/packages/#{app.name}-#{Base.encode16(:crypto.strong_rand_bytes(8))}.ez",
        else: "packages/#{app.name}.ez"

    output = Path.join(app.path, relative)
    File.mkdir_p!(Path.dirname(output))
    run!(app.path, :prod, ["deps.get"], report)
    run!(app.path, :prod, ["nerves_gate.package", "--output", output], report)
    output
  end

  def install!(path, device, report \\ fn _ -> :ok end) do
    output = package!(path, report, :temporary)

    try do
      case Simulator.QemuTests.install(device, output) do
        {:ok, id} -> await_install!(id, report)
        {:error, message} -> raise ArgumentError, message
      end
    after
      File.rm(output)
    end
  end

  defp await_install!(id, report) do
    run =
      Enum.find(Simulator.QemuTests.snapshot().runs, &(&1.id == id)) ||
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

  defp run!(path, env, args, report) do
    {:ok, _} = Application.ensure_all_started(:muontrap)

    status =
      Simulator.BuildOutput.run(
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

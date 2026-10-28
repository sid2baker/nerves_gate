defmodule Workbench.Plugins do
  @moduledoc "Ordinary SDK plugin projects opened by the workbench."
  use GenServer

  @reserved ~w(dev dev_web workbench workbench_web scenarios nerves_gate nerves_gate_dev nerves_gate_workbench nerves_gate_sdk simulator)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def list, do: GenServer.call(__MODULE__, :list)
  def open(path), do: GenServer.call(__MODULE__, {:open, path})

  def init(_), do: {:ok, %{}}

  def handle_call(:list, _, state),
    do: {:reply, state |> Map.values() |> Enum.sort_by(& &1.path), state}

  def handle_call({:open, path}, _, state) do
    plugin = project!(path)
    {:reply, {:ok, plugin}, Map.put(state, plugin.path, plugin)}
  rescue
    error in [ArgumentError, File.Error] -> {:reply, {:error, Exception.message(error)}, state}
  end

  def project!(path) when is_binary(path) and path != "" do
    path = Path.expand(path)

    unless File.regular?(Path.join(path, "mix.exs")),
      do: raise(ArgumentError, "No Mix application at #{path}")

    if path == Workbench.root(),
      do: raise(ArgumentError, "Open a plugin, not the platform project")

    %{path: path, name: Path.basename(path)}
  end

  def project!(_), do: raise(ArgumentError, "Supply the plugin directory")

  def create(path, opts \\ []) do
    plugin = scaffold!(path, opts)
    open(plugin.path)
  rescue
    error in [ArgumentError, File.Error] -> {:error, Exception.message(error)}
  end

  @doc "Scaffold files without requiring a running Workbench session."
  def scaffold!(path, opts \\ []) do
    local_sdk = Keyword.get(opts, :local_sdk, false)
    path = Path.expand(path)
    name = Path.basename(path)
    validate_name!(name)
    if name in @reserved, do: raise(ArgumentError, "#{name} is a platform application name")
    if File.exists?(path), do: raise(ArgumentError, "Refusing to overwrite #{path}")

    bindings = [
      app: name,
      module: Macro.camelize(name),
      source: if(local_sdk, do: Workbench.root())
    ]

    templates = Path.join(Workbench.root(), "priv/templates/plugin")

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

  defp validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
      do: raise(ArgumentError, "Names must contain lowercase letters, digits and underscores")
  end

  def test!(path, report \\ fn _ -> :ok end) do
    Workbench.BuildLock.run!(
      fn ->
        plugin = project!(path)
        run!(plugin.path, :test, ["deps.get"], report)
        run!(plugin.path, :test, ["deps.compile"], report)
        run!(plugin.path, :test, ["test"], report)
        :ok
      end,
      path
    )
  end

  def package!(path, report \\ fn _ -> :ok end, destination \\ :release) do
    Workbench.BuildLock.run!(
      fn ->
        plugin = project!(path)

        relative =
          if destination == :temporary do
            "_build/packages/#{plugin.name}-#{Base.encode16(:crypto.strong_rand_bytes(8))}.ez"
          else
            "packages/#{plugin.name}.ez"
          end

        output = Path.join(plugin.path, relative)
        File.mkdir_p!(Path.dirname(output))
        run!(plugin.path, :prod, ["deps.get"], report)
        run!(plugin.path, :prod, ["deps.compile"], report)
        run!(plugin.path, :prod, ["nerves_gate.package", "--output", output], report)
        output
      end,
      path
    )
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

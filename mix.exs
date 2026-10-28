defmodule Workbench.MixProject do
  use Mix.Project

  # Setup can load this OTP-only installer before dependencies are compiled.
  @compile {:no_warn_undefined, Tailscaled.Installer}

  @external_resource Path.join(__DIR__, "VERSION")
  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()
  @projects ~w(sdk firmware)

  def project do
    # A device target left in the caller's shell must not select a device build
    # for the workstation project. Firmware tasks select their own target in
    # firmware/; keep the caller's environment unchanged for those commands.
    Mix.target(:host)

    [
      app: :nerves_gate_workbench,
      version: @version,
      elixir: "~> 1.20",
      test_ignore_filters: [~r"/support/"],
      listeners: if(Mix.env() == :dev, do: [Phoenix.CodeReloader], else: []),
      deps: [
        {:nerves_gate_sdk, path: "sdk"},
        {:nerves_gate, path: "firmware", runtime: false},
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.2.13"},
        {:bandit, "~> 1.12"},
        {:req, "~> 0.7"},
        {:nerves_discovery, "~> 0.1.6"},
        {:floki, "~> 0.38"},
        {:volt, "~> 0.23.0", only: [:dev, :test]},
        {:phoenix_live_reload, "~> 1.5", only: :dev},
        {:tidewave, "~> 0.9", only: :dev}
      ],
      aliases: [
        setup: &setup/1,
        "deps.get": &deps_get/1,
        format: &format/1,
        firmware: &firmware/1,
        ci: &ci/1,
        check: &check/1,
        "test.sdk": &run("sdk", ["test" | &1])
      ]
    ]
  end

  # No UI, devices, networking services or release actions start implicitly.
  def application,
    do: [extra_applications: [:logger, :crypto, :ssh, :eex], mod: {Workbench.Application, []}]

  def cli, do: [preferred_envs: [ci: :test, check: :test, "test.qemu": :test]]

  defp deps_get(args) do
    for project <- @projects, do: run(project, ["deps.get" | args])
    Mix.Tasks.Deps.Get.run(args)
  end

  defp setup([]) do
    Mix.Task.run("local.hex", ["--force", "--if-missing"])
    Mix.Task.run("local.rebar", ["--force", "--if-missing"])
    Application.load(:nerves_bootstrap)
    bootstrap = Application.spec(:nerves_bootstrap, :vsn)

    unless bootstrap && Version.match?(to_string(bootstrap), "~> 1.17"),
      do: Mix.Task.run("archive.install", ["hex", "nerves_bootstrap", "~> 1.17", "--force"])

    deps_get(["--check-locked"])
    run("firmware", ["deps.get", "--check-locked"], target: :x86_64)

    unless Code.ensure_loaded?(Tailscaled.Installer),
      do: Code.require_file("firmware/deps/tailscaled_ex/lib/tailscaled/installer.ex", __DIR__)

    Tailscaled.Installer.install!(
      Path.join(__DIR__, "firmware/rootfs_overlay/x86_64/usr/sbin/tailscaled"),
      arch: "amd64",
      version: "1.104.1",
      sha256: "108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528",
      cache_dir: Path.join(__DIR__, "firmware/_build/setup")
    )

    # Enter the archive task before dependency task lookup can compile target
    # ports with host CC. This prepares artifacts only, never device code.
    run("firmware", ["nerves_bootstrap.init"], target: :x86_64)
    # Resolve the simulator task in the root's host graph, which includes the
    # workbench's optional reload tools and matching endpoint configuration.
    # Artifact setup compiled Nerves tooling in the target graph; its completed
    # dependency tasks must not skip the root's independent host compilation.
    Mix.Task.clear()
    Mix.Task.run("loadconfig")
    Mix.Task.run("qemu.setup")

    Mix.shell().info(
      "Ready. Run mix dev, then create/open apps and explicitly start simulated devices."
    )
  end

  defp setup(_), do: Mix.raise("Usage: mix setup")

  defp firmware(args) do
    {options, targets} = OptionParser.parse!(args, strict: [env: :string])
    target = List.first(targets) || "x86_64"
    env = options[:env] || "dev"

    unless length(targets) <= 1 and
             {target, env} in [{"x86_64", "dev"}, {"ec100", "dev"}, {"ec100", "prod"}],
           do: Mix.raise("Usage: mix firmware [x86_64 | ec100] [--env dev | prod]")

    Mix.Task.run("app.config")
    env = if env == "prod", do: :prod, else: :dev
    Workbench.Builds.firmware!(target, &Mix.shell().info(&1), env)
  end

  defp format(args), do: Mix.Tasks.Format.run(args)

  defp ci([]), do: checks("ci")
  defp ci(_), do: Mix.raise("Usage: mix ci")
  defp check([]), do: checks("check")
  defp check(_), do: Mix.raise("Usage: mix check")

  defp checks(task) do
    for project <- @projects do
      Mix.shell().info("==> #{project}: mix #{task}")
      run(project, [task])
    end

    # Compile the root last: independent projects may load their own copies of
    # shared host modules. Restore the root config before its compile and tests.
    Mix.Task.clear()
    Mix.Task.run("loadconfig")
    Mix.Task.run("compile", ["--warnings-as-errors"])
    Workbench.Builds.assets!(&Mix.shell().info(&1))
    Mix.Tasks.Format.run(["--check-formatted"])
    Mix.Task.run("test", ["--max-cases", "4"])

    for plugin <- ["tailnet_subrouter", "modbus"],
        do: Workbench.Plugins.test!(Path.join([__DIR__, "plugins", plugin]))
  end

  # Host-only native orchestration. Nerves device builds and user apps run
  # in supervised OS processes instead; their compiler state must be isolated.
  defp project_modules(app) do
    path = Path.join([Mix.Project.app_path(), "ebin", "#{app}.app"])

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, ^app, spec}]} -> spec[:modules] || []
      _ -> []
    end
  end

  defp restore_modules(modules, before) do
    Enum.each(modules, fn module ->
      previous = Map.get(before, module)

      case :code.is_loaded(module) do
        {:file, ^previous} ->
          :ok

        false ->
          :ok

        {:file, _} ->
          unless :code.soft_purge(module) and :code.delete(module) and :code.soft_purge(module),
            do: Mix.raise("Host checks left executing subsystem code: #{inspect(module)}")

          restore_module(module, previous)
      end
    end)
  end

  defp restore_module(module, path) when is_list(path) do
    absolute =
      path |> to_string() |> Path.expand() |> Path.rootname(".beam") |> String.to_charlist()

    case :code.load_abs(absolute) do
      {:module, ^module} -> :ok
      _ -> Mix.raise("Could not restore root module #{inspect(module)} after host checks")
    end
  end

  defp restore_module(_, _), do: :ok

  defp run(project, [task | args], options \\ []) do
    target = options[:target] || :host

    if target != :host and task not in ["deps.get", "nerves_bootstrap.init"],
      do: Mix.raise("Device compilation must run in a separate OS process")

    apps = %{"sdk" => :nerves_gate_sdk, "firmware" => :nerves_gate}
    app = Map.fetch!(apps, project)
    running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == app))
    previous_env = Mix.env()
    previous_target = Mix.target()
    root = Mix.Project.pop()
    previous = System.get_env()
    code_path = :code.get_path()
    compiler_options = Code.compiler_options()
    gateway_env = Application.get_all_env(:nerves_gate)

    loaded_modules =
      Map.new(:code.all_loaded(), fn {module, path} ->
        {module,
         if(is_list(path),
           do: path |> to_string() |> Path.expand() |> String.to_charlist(),
           else: path
         )}
      end)

    try do
      # Root code-reload config must not leak into standalone subsystem builds
      # which intentionally do not include the workstation's optional tools.
      Application.delete_env(:nerves_gate, NervesGateWeb.Endpoint)
      Code.compiler_options(ignore_module_conflict: true)
      System.put_env("NERVES_GATE_LOCAL_DEPS", "1")
      System.delete_env("NERVES_GATE_DEVICE_NODE")
      Mix.env(if task in ["test", "ci", "check"], do: :test, else: previous_env)
      Mix.target(target)

      Mix.Project.in_project(Map.fetch!(apps, project), Path.join(__DIR__, project), fn _ ->
        try do
          Mix.Task.clear()
          Mix.Task.run("loadconfig")
          Mix.Task.run(task, args)
        after
          if not running?, do: Application.stop(app)
          restore_modules(project_modules(app), loaded_modules)
        end
      end)
    after
      # Host tests may start the subsystem's application. Do not leave its
      # PubSub or supervisors alive when returning to a different project.
      if not running?, do: Application.stop(app)
      Code.compiler_options(compiler_options)
      :code.set_path(code_path)
      Mix.env(previous_env)
      Mix.target(previous_target)

      for key <- Map.keys(System.get_env()),
          not Map.has_key?(previous, key),
          do: System.delete_env(key)

      System.put_env(previous)

      for {key, _} <- Application.get_all_env(:nerves_gate),
          do: Application.delete_env(:nerves_gate, key)

      Application.put_all_env(nerves_gate: gateway_env)
      Mix.Project.push(root.name, root.file)
    end
  end
end

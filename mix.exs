defmodule NervesGate.Repository do
  use Mix.Project

  # Nerves systems are not formatted here: their mix.exs files are artifact inputs.
  @projects ~w(sdk sim new firmware tools)

  def project do
    [
      elixir: "~> 1.20",
      aliases: [
        setup: &setup/1,
        "deps.get": &deps_get/1,
        format: &format/1,
        test: &test/1,
        "dev.workspace": &dev_workspace/1,
        ci: &ci/1,
        dev: &run("sim", ["qemu.dev" | &1]),
        "dev.status": &run("sim", ["qemu.status" | &1]),
        "dev.stop": &run("sim", ["qemu.stop" | &1]),
        "dev.ui": &run("sim", ["dev.ui" | &1]),
        "test.sdk": &run("sdk", ["test" | &1]),
        "test.sim": &run("sim", ["test" | &1]),
        "test.firmware": &run("sim", ["qemu.test" | &1])
      ]
    ]
  end

  # Host-only dependency preparation for CI; no system downloads or device tools.
  defp deps_get(args) do
    for project <- @projects, do: run(project, ["deps.get" | args])
  end

  # Prepares every project and the QEMU firmware inputs. Never boots a device.
  defp setup([]) do
    Mix.Task.run("local.hex", ["--force", "--if-missing"])
    Mix.Task.run("local.rebar", ["--force", "--if-missing"])
    Application.load(:nerves_bootstrap)
    bootstrap = Application.spec(:nerves_bootstrap, :vsn)

    unless bootstrap && Version.match?(to_string(bootstrap), "~> 1.17"),
      do: Mix.Task.run("archive.install", ["hex", "nerves_bootstrap", "~> 1.17", "--force"])

    # Fetch every dependency graph before loading compiled project tasks: their
    # consolidated protocols must not replace the protocols used by Hex.
    for project <- ~w(sdk new sim), do: run(project, ["deps.get", "--check-locked"])
    run("firmware", ["deps.get", "--check-locked"], target: "x86_64")
    run("firmware", ["tailscaled.install"], target: "x86_64")
    Mix.shell().info("Downloading the prebuilt EC100 QEMU system (cached afterwards).")
    run("firmware", ["nerves.artifact.get"], target: "x86_64")
    run("sim", ["qemu.setup"])
    Mix.shell().info("Ready. Run mix dev, then start devices at http://localhost:4000.")
  end

  defp setup(_), do: Mix.raise("Usage: mix setup")

  defp format(args) do
    Mix.Tasks.Format.run(args)
    for project <- @projects, do: run(project, ["format" | args])
  end

  defp test(args) do
    for project <- @projects, do: run(project, ["test" | args])
  end

  defp ci([]) do
    Mix.Tasks.Format.run(["--check-formatted"])

    for project <- @projects do
      Mix.shell().info("==> #{project}: mix ci")
      run(project, ["ci"])
    end
  end

  defp ci(_), do: Mix.raise("Usage: mix ci")

  defp dev_workspace([]) do
    path = Path.join(System.tmp_dir!(), "gate_dev_#{System.system_time(:microsecond)}")
    run("new", ["do", "compile", "+", "nerves_gate.new", path, "--local", __DIR__])

    Mix.shell().info("""
    Local workspace ready. Nothing has been started or published.
      cd #{path}
      mix setup
      mix test
      mix sim
    Remove #{path} when finished.
    """)
  end

  defp dev_workspace(_), do: Mix.raise("Usage: mix dev.workspace")

  defp put_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp run(project, [task | args], options \\ []) do
    apps = %{
      "sdk" => :nerves_gate_sdk,
      "sim" => :nerves_gate_sim,
      "new" => :nerves_gate_new,
      "firmware" => :nerves_gate,
      "tools" => :nerves_gate_tools,
      "systems/nerves_system_ec100" => :nerves_system_ec100,
      "systems/nerves_system_ec100_qemu" => :nerves_system_ec100_qemu
    }

    previous_env = Mix.env()
    previous_target = Mix.target()
    # These are independent projects, not dependencies of the orchestration root.
    root = Mix.Project.pop()

    env = %{
      "NERVES_GATE_LOCAL_DEPS" => "1",
      "NERVES_GATE_DEVICE_NODE" => nil
    }

    # Nerves exports toolchain variables while preparing a target. None may
    # leak into the next independent project's host compilation.
    previous = System.get_env()

    # Compilation prunes code paths to the project's own dependencies (dropping
    # OTP apps such as ssl and archives such as nerves_bootstrap). Restore them.
    code_path = :code.get_path()
    compiler_options = Code.compiler_options()

    try do
      # Independent builds can compile the same modules (firmware is also a
      # simulator dependency). Replacing that loaded code is intentional here;
      # all other compiler warnings still fail each project's CI.
      Code.compiler_options(ignore_module_conflict: true)
      put_env(env)

      # Tests use :test; everything else follows the root (MIX_ENV, default dev).
      Mix.env(if task in ["test", "qemu.test", "ci"], do: :test, else: previous_env)

      Mix.target(
        case options[:target] do
          "ec100" -> :ec100
          "x86_64" -> :x86_64
          _ -> :host
        end
      )

      Mix.Project.in_project(Map.fetch!(apps, project), Path.join(__DIR__, project), fn _ ->
        Mix.Task.clear()
        Mix.Task.run("loadconfig")
        Mix.Task.run(task, args)
      end)
    after
      Code.compiler_options(compiler_options)
      :code.set_path(code_path)
      Mix.env(previous_env)
      Mix.target(previous_target)

      for key <- Map.keys(System.get_env()),
          not Map.has_key?(previous, key),
          do: System.delete_env(key)

      System.put_env(previous)
      Mix.Project.push(root.name, root.file)
    end
  end
end

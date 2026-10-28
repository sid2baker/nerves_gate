defmodule Workbench.Skill.DevEnvironment do
  use Pi.Skill.Script

  skill do
    name("dev-environment")

    description(
      "Attach pi-elixir to the running checkout's hidden mix dev node, before inspecting its physical or QEMU gateways."
    )

    markdown("""
    # Attach to the development workspace

    The user owns `mix dev`. Do not launch/stop it or boot devices without permission.
    In `elixir_eval` with target `bridge`, call:

    ```elixir
    Workbench.Skill.DevEnvironment.attach("/absolute/path/to/nerves_gate")
    ```

    Then use `elixir_eval` with target `runtime`:

    ```elixir
    Node.self()
    Workbench.DeviceInspection.devices()
    ```

    Mix tasks and Pi use the same attachment: distribution with cookie `mycookie`.
    Resolve this checkout's current session before device operations and reattach
    after Workbench restarts or node changes; no Pi restart is needed. An error means
    stop and inspect; do not create
    a second device-connection loop or load project source into Pi's bridge.
    Keep project target for source work, runtime for Workbench/device inspection.
    Attachment verifies the same Session handshake as CLI. A stale compatibility
    report permits inspection, not mutation; coordinate a user-owned session restart.
    Prefer `mix gateway.list/inspect/logs`, `mix scenario.run ID --device TARGET`,
    and the documented named Jobs/Runner operations over raw RPC. If the installed
    bridge refuses retargeting, report that limitation; do not bypass this skill.
    """)
  end

  def apis,
    do: [Pi.Plugin.API.new(name: :dev_environment, module: __MODULE__, alias: :DevEnvironment)]

  def attach(root) do
    %{"node" => name, "id" => id} =
      root |> Path.join("_build/workbench/session.json") |> File.read!() |> JSON.decode!()

    unless Node.alive?() do
      epmd =
        Path.join([
          to_string(:code.root_dir()),
          "erts-#{:erlang.system_info(:version)}",
          "bin/epmd"
        ])

      {_, 0} = System.cmd(epmd, ["-daemon"])

      {:ok, _} =
        Node.start(String.to_atom("pi_#{id}_#{System.pid()}@127.0.0.1"),
          name_domain: :longnames,
          hidden: true
        )
    end

    result = Pi.Target.Attached.status(node: name, cookie: :mycookie)

    case result do
      %{connected: true, node: node, project_root: cwd} ->
        {canonical, 0} = System.cmd("pwd", ["-P"], cd: Path.expand(root))
        canonical = String.trim(canonical)
        remote = :erpc.call(node, Workbench.Session, :handshake, [], 5_000)

        expected = %{
          root: canonical,
          id: id,
          compatibility: :erpc.call(node, Workbench.Session, :compatibility, [canonical], 5_000)
        }

        :ok = :erpc.call(node, Workbench.Session, :validate, [remote, expected, false], 5_000)
        true = :erpc.call(node, Workbench.Session, :locked?, [], 5_000)

        mutation_preflight =
          :erpc.call(node, Workbench.Session, :validate, [remote, expected, true], 5_000)

        # A replacement during verification requires a fresh attachment, not a
        # successful response for a session that is no longer current.
        %{"node" => ^name, "id" => ^id} =
          root |> Path.join("_build/workbench/session.json") |> File.read!() |> JSON.decode!()

        System.put_env("PI_ELIXIR_NODE", name)
        System.put_env("PI_ELIXIR_COOKIE", "mycookie")
        {:ok, %{node: node, root: cwd, session_id: id, mutation_preflight: mutation_preflight}}

      error ->
        {:error, error}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end

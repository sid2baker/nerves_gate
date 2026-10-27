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
    Reattach after Workbench restarts. An error means stop and inspect; do not create
    a second device-connection loop or load project source into Pi's bridge.
    Keep project target for source work, runtime for Workbench/device inspection.
    """)
  end

  def apis,
    do: [Pi.Plugin.API.new(name: :dev_environment, module: __MODULE__, alias: :DevEnvironment)]

  def attach(root) do
    %{"node" => name, "id" => id} =
      root |> Path.join("_build/workbench/session.json") |> File.read!() |> JSON.decode!()

    if System.get_env("PI_ELIXIR_NODE") not in [nil, name],
      do:
        raise(
          "Restart Pi to attach to a different checkout/runtime; the installed bridge pins its runtime identity"
        )

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

    node = String.to_atom(name)
    result = Pi.Target.Attached.status(node: node, cookie: :mycookie)

    case result do
      %{connected: true, project_root: cwd} ->
        true = Path.expand(cwd) == Path.expand(root)
        ^id = :erpc.call(node, System, :get_env, ["WORKBENCH_SESSION_ID"], 5_000)
        System.put_env("PI_ELIXIR_NODE", name)
        System.put_env("PI_ELIXIR_COOKIE", "mycookie")
        {:ok, %{node: node, root: cwd}}

      error ->
        {:error, error}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end

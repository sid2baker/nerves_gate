defmodule Workbench.QemuCLI do
  @moduledoc """
  Run scenarios, or change the lifecycle, of the running mix dev simulator.

      mix test.qemu                               # every scenario on the first device
      mix test.qemu --only cable_loss --device gateway_b
      mix test.qemu --lifecycle start|stop|reset  # reset erases every device disk

  Disposable CI benches use `--ci` and never attach to the user's session.

  Scenarios marked for all devices hold every device for their run.
  """

  #  "Run scenarios or --lifecycle start|stop|reset on the existing simulator"

  def run(args) do
    options = options!(args)

    if options[:ci] do
      Workbench.Launcher.run(args)
    else
      {client, state} = session() || Mix.raise("Start mix dev first.")
      run_existing(client, state, options)
    end
  end

  # The running session's site, over its private Unix socket; nil without one.
  defdelegate session(), to: Workbench.Session, as: :connect

  # Never print HTTP error pages: development pages can include private state.
  defp api_body!(%{status: 200, body: body}) when is_map(body), do: body

  defp api_body!(%{status: status}),
    do:
      Mix.raise(
        "Simulator API unavailable (HTTP #{status}). Restart mix dev after configuration changes."
      )

  defp options!(args) do
    {options, []} =
      OptionParser.parse!(args,
        strict: [
          ci: :boolean,
          only: :string,
          device: :string,
          lifecycle: :string,
          config: :string
        ]
      )

    if options[:lifecycle] && (options[:ci] || options[:only] || options[:device]),
      do: Mix.raise("Use --lifecycle start|stop|reset without --ci, --only or --device")

    if options[:lifecycle] && options[:lifecycle] not in ~w(start stop reset),
      do: Mix.raise("Expected --lifecycle start|stop|reset; reset erases all device disks")

    if options[:ci] && options[:device],
      do: Mix.raise("CI runs on the first configured device")

    validate_config!(options[:config], options[:ci])
    options
  end

  defp validate_config!(nil, _), do: :ok
  defp validate_config!(_, true), do: :ok

  defp validate_config!(_, _),
    do: Mix.raise("Use --config only with --ci; mix dev owns the running session's configuration")

  defp run_existing(client, state, options) do
    if action = options[:lifecycle] do
      result = api_body!(Req.post!(client, url: "/api/control", form: [lifecycle: action]))
      if result["error"], do: Mix.raise(result["error"])
      IO.puts("#{action} accepted; live progress on the simulator site")
      await_lifecycle(client, action, System.monotonic_time(:millisecond) + 900_000, nil)
    else
      [%{"id" => first} | _] = state["lifecycle"]["devices"]
      device = options[:device] || first
      form = [device: device, scenario: options[:only] || "all"]
      run = api_body!(Req.post!(client, url: "/api/run", form: form))
      if run["error"], do: Mix.raise(run["error"])
      IO.puts("Run ##{run["id"]} on #{device}; live results on /devices/#{device}")
      wait(client, run["id"], MapSet.new())
    end
  end

  defp await_lifecycle(client, action, deadline, previous) do
    view = api_body!(Req.get!(client, url: "/api/state"))["lifecycle"]
    if view["phase"] != previous, do: IO.puts(view["phase"])
    target = if action == "start", do: "ready", else: "stopped"

    cond do
      view["status"] == target ->
        :ok

      view["status"] in ["failed", "unavailable"] ->
        Mix.raise(view["phase"])

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("Lifecycle outcome unknown. Inspect the site; do not replay automatically.")

      true ->
        Process.sleep(250)
        await_lifecycle(client, action, deadline, view["phase"])
    end
  end

  @doc false
  def wait(client, id, seen) do
    state = api_body!(Req.get!(client, url: "/api/state"))
    run = Enum.find(state["runs"], &(&1["id"] == id)) || Mix.raise("Run ##{id} is no longer kept")

    seen =
      Enum.reduce(run["rows"], seen, fn row, seen ->
        if row["status"] in ["passed", "failed", "skipped"] and
             not MapSet.member?(seen, row["id"]) do
          IO.puts("#{row["status"]}: #{row["id"]} (#{row["milliseconds"]} ms) #{row["detail"]}")
          MapSet.put(seen, row["id"])
        else
          seen
        end
      end)

    case run["status"] do
      "running" ->
        Process.sleep(250)
        wait(client, id, seen)

      "passed" ->
        :ok

      "skipped" ->
        Mix.raise("No applicable scenarios ran; inspect the reported requirements")

      _ ->
        Mix.raise("Simulator run failed; inspect the device page")
    end
  end
end

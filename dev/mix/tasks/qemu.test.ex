defmodule Mix.Tasks.Qemu.Test do
  @moduledoc """
  Run scenarios, or change the lifecycle, of the running mix dev simulator.

      mix test                                  # every scenario on the first device
      mix test --only cable_loss --device gateway_b
      mix test --lifecycle start|stop|reset     # reset erases every device disk

  Scenarios marked for all devices hold every device for their run.
  """
  use Mix.Task
  @shortdoc "Run scenarios or --lifecycle start|stop|reset on the existing simulator"

  @impl true
  def run(args) do
    options = options!(args)

    if options[:ci] do
      Mix.Task.run("dev", args)
    else
      {client, state} = session() || Mix.raise("Start mix dev first.")
      run_existing(client, state, options)
    end
  end

  # The running session's site, over its private Unix socket; nil without one.
  def session do
    socket = Path.expand("_build/qemu-dev/http.sock")
    {:ok, _} = Application.ensure_all_started(:req)

    client =
      Req.new(
        base_url: "http://localhost",
        unix_socket: socket,
        retry: false,
        redirect: false,
        receive_timeout: 10_000
      )

    with true <- File.exists?(socket),
         {:ok, %{status: 200, body: %{"epmd_port" => _}} = response} <-
           Req.get(client, url: "/api/state") do
      cookie =
        response
        |> Req.Response.get_header("set-cookie")
        |> Enum.map_join("; ", &(String.split(&1, ";", parts: 2) |> hd()))

      headers = [cookie: cookie, "x-csrf-token": response.body["csrf_token"]]
      {Req.merge(client, headers: headers), response.body}
    else
      {:ok, _} ->
        Mix.raise("Simulator API unavailable. Restart mix dev after configuration changes.")

      _ ->
        nil
    end
  end

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
        strict: [ci: :boolean, only: :string, device: :string, lifecycle: :string]
      )

    if options[:lifecycle] && (options[:ci] || options[:only] || options[:device]),
      do: Mix.raise("Use --lifecycle start|stop|reset without --ci, --only or --device")

    if options[:lifecycle] && options[:lifecycle] not in ~w(start stop reset),
      do: Mix.raise("Expected --lifecycle start|stop|reset; reset erases all device disks")

    if options[:ci] && options[:device],
      do: Mix.raise("CI runs on the first configured device")

    options
  end

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

  defp wait(client, id, seen) do
    state = api_body!(Req.get!(client, url: "/api/state"))
    run = Enum.find(state["runs"], &(&1["id"] == id)) || Mix.raise("Run ##{id} is no longer kept")

    seen =
      Enum.reduce(run["rows"], seen, fn row, seen ->
        if row["status"] in ["passed", "failed"] and not MapSet.member?(seen, row["id"]) do
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

      _ ->
        Mix.raise("QEMU scenarios failed")
    end
  end
end

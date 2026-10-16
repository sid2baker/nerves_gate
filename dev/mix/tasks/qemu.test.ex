defmodule Mix.Tasks.Qemu.Test do
  @moduledoc false
  use Mix.Task
  @shortdoc "Run scenarios or --lifecycle start|stop|reset on the existing simulator"

  @impl true
  def run(args) do
    options = options!(args)

    if options[:ci],
      do: Mix.Task.run("dev", args),
      else: run_existing(client(), options)
  end

  defp options!(args) do
    {options, []} =
      OptionParser.parse!(args, strict: [ci: :boolean, only: :string, lifecycle: :string])

    if options[:lifecycle] && (options[:ci] || options[:only]),
      do: Mix.raise("Use --lifecycle start|stop|reset without --ci or --only")

    if options[:lifecycle] && options[:lifecycle] not in ~w(start stop reset),
      do: Mix.raise("Expected --lifecycle start|stop|reset; reset erases all device disks")

    options
  end

  defp client do
    socket = Path.expand("_build/qemu-dev/http.sock")
    unless File.exists?(socket), do: Mix.raise("Start mix dev, then open /tests")
    {:ok, _} = Application.ensure_all_started(:req)

    client =
      Req.new(
        base_url: "http://localhost",
        unix_socket: socket,
        retry: false,
        redirect: false,
        receive_timeout: 10_000,
        http_errors: :raise
      )

    response = Req.get!(client, url: "/tests/state")

    cookie =
      response
      |> Req.Response.get_header("set-cookie")
      |> Enum.map_join("; ", &(String.split(&1, ";", parts: 2) |> hd()))

    Req.merge(client, headers: [cookie: cookie, "x-csrf-token": response.body["csrf_token"]])
  end

  defp run_existing(client, options) do
    if action = options[:lifecycle] do
      result = Req.post!(client, url: "/tests/control", form: [lifecycle: action]).body
      if result["error"], do: Mix.raise(result["error"])
      IO.puts("#{action} accepted; live progress on /tests")
      await_lifecycle(client, action, System.monotonic_time(:millisecond) + 900_000, nil)
    else
      run = Req.post!(client, url: "/tests/run", form: [scenario: options[:only] || "all"]).body
      if run["error"], do: Mix.raise(run["error"])
      IO.puts("Run ##{run["id"]}; live results on /tests")
      wait(client, run["id"], MapSet.new())
    end
  end

  defp await_lifecycle(client, action, deadline, previous) do
    view = Req.get!(client, url: "/tests/state").body["lifecycle"]
    if view["phase"] != previous, do: IO.puts(view["phase"])
    target = if action == "start", do: "ready", else: "stopped"

    cond do
      view["status"] == target ->
        :ok

      view["status"] in ["failed", "unavailable"] ->
        Mix.raise(view["phase"])

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("Lifecycle outcome unknown. Inspect /tests; do not replay automatically.")

      true ->
        Process.sleep(250)
        await_lifecycle(client, action, deadline, view["phase"])
    end
  end

  defp wait(client, id, seen) do
    state = Req.get!(client, url: "/tests/state").body
    if state["id"] != id, do: Mix.raise("Run was replaced; see /tests")

    seen =
      Enum.reduce(state["rows"], seen, fn row, seen ->
        if row["status"] in ["passed", "failed"] and not MapSet.member?(seen, row["id"]) do
          IO.puts("#{row["status"]}: #{row["id"]} (#{row["milliseconds"]} ms) #{row["detail"]}")
          MapSet.put(seen, row["id"])
        else
          seen
        end
      end)

    case state["status"] do
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

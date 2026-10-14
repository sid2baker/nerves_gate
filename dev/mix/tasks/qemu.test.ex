defmodule Mix.Tasks.Qemu.Test do
  @moduledoc false
  use Mix.Task
  @shortdoc "Run scenarios on the existing QEMU, or boot a clean CI session with --ci"

  @impl true
  def run(args) do
    {options, []} = OptionParser.parse!(args, strict: [ci: :boolean, only: :string])

    if options[:ci] do
      Mix.Task.run("dev.qemu", args)
    else
      socket = Path.expand("_build/qemu-dev/http.sock")
      unless File.exists?(socket), do: Mix.raise("Start mix dev.qemu, then open /tests")
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

      client =
        Req.merge(client,
          headers: [cookie: cookie, "x-csrf-token": response.body["csrf_token"]]
        )

      run =
        Req.post!(client, url: "/tests/run", form: [scenario: options[:only] || "all"]).body

      if run["error"], do: Mix.raise(run["error"])
      IO.puts("Run ##{run["id"]}; live results on /tests")
      wait(client, run["id"], MapSet.new())
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

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
      cookie = Path.join(System.tmp_dir!(), "qemu-tests-#{System.pid()}.cookie")
      File.write!(cookie, "")
      File.chmod!(cookie, 0o600)

      try do
        state = request(socket, cookie, "/tests/state", [])

        run =
          request(socket, cookie, "/tests/run", [
            "-H",
            "x-csrf-token: #{state["csrf_token"]}",
            "--data-urlencode",
            "scenario=#{options[:only] || "all"}"
          ])

        if run["error"], do: Mix.raise(run["error"])
        IO.puts("Run ##{run["id"]}; live results on /tests")
        wait(socket, cookie, run["id"], MapSet.new())
      after
        File.rm(cookie)
      end
    end
  end

  defp wait(socket, cookie, id, seen) do
    state = request(socket, cookie, "/tests/state", [])
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
        wait(socket, cookie, id, seen)

      "passed" ->
        :ok

      _ ->
        Mix.raise("QEMU scenarios failed")
    end
  end

  defp request(socket, cookie, path, args) do
    {body, status} =
      System.cmd(
        "curl",
        [
          "--silent",
          "--show-error",
          "--fail-with-body",
          "--max-time",
          "10",
          "--unix-socket",
          socket,
          "-b",
          cookie,
          "-c",
          cookie
        ] ++ args ++ ["http://localhost#{path}"]
      )

    if status != 0, do: Mix.raise("QEMU page unavailable: #{body}")
    Jason.decode!(body)
  end
end

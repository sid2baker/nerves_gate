defmodule Mix.Tasks.Qemu.Status do
  @moduledoc "Inspect this checkout's simulator session without starting or stopping it."
  use Mix.Task
  @shortdoc "Show simulator session status, URL and launcher PID"

  def run([]) do
    Mix.Task.run("compile")
    IO.puts(NervesGateSim.DevSession.describe(NervesGateSim.DevSession.status()))
  end
end

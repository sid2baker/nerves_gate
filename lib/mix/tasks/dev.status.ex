defmodule Mix.Tasks.Dev.Status do
  @moduledoc "Inspect this checkout's simulator session without starting or stopping it."
  use Mix.Task
  @shortdoc "Show simulator session status, URL and launcher PID"

  def run([]) do
    Mix.Task.run("compile")
    IO.puts(Dev.Session.describe(Dev.Session.status()))
  end
end

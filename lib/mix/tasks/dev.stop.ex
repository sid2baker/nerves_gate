defmodule Mix.Tasks.Dev.Stop do
  @moduledoc "Stop this checkout's idle simulator session and wait for its lock to be released."
  use Mix.Task
  @shortdoc "Gracefully stop the simulator session (not just devices)"

  def run([]) do
    Mix.Task.run("compile")

    case Workbench.Session.stop() do
      :ok -> IO.puts("No simulator session is running; the session lock is free.")
      {:error, message} -> Mix.raise(message)
    end
  end
end

defmodule Mix.Tasks.Dev.Stop do
  use Mix.Task
  @shortdoc "Gracefully stop this checkout's idle Workbench session"
  @requirements ["app.config"]

  def run([]) do
    case Workbench.Session.stop() do
      :ok -> IO.puts("No Workbench session is running.")
      {:error, message} -> Mix.raise(message)
    end
  end
end

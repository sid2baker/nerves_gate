defmodule Workbench.BuildLock do
  @moduledoc "Cross-process exclusion for shared checkout build outputs; never deletes lock files."

  def run!(fun, directory \\ Workbench.root()) do
    directory = Workbench.Session.canonical_root(directory)
    key = {__MODULE__, directory}

    if Process.get(key) do
      fun.()
    else
      path = Path.join(directory, "_build/workbench-build.lock")
      File.mkdir_p!(Path.dirname(path))
      flock = System.find_executable("flock") || raise "Install flock (util-linux)"
      shell = System.find_executable("sh") || raise "Install a POSIX shell"

      port =
        Port.open({:spawn_executable, flock}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "--nonblock",
            "--conflict-exit-code",
            "75",
            "--no-fork",
            path,
            shell,
            "-c",
            "printf 'locked\\n'; read -r release"
          ]
        ])

      try do
        receive do
          {^port, {:data, "locked\n"}} ->
            :ok

          {^port, {:exit_status, 75}} ->
            raise "Another build/test/package owns shared checkout outputs; wait for it to finish."

          {^port, {:exit_status, status}} ->
            raise "Build lock failed (exit #{status})"
        after
          5_000 -> raise "Build lock did not respond; no build started"
        end

        Process.put(key, true)
        fun.()
      after
        Process.delete(key)
        if Port.info(port), do: Port.close(port)
      end
    end
  end
end

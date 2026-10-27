defmodule Workbench.Session do
  @moduledoc """
  This checkout's `mix dev` session: a flock-held, uniquely named hidden node.
  Clients (Mix tasks, Pi) attach over distribution and call ordinary functions.
  """

  @dir "_build/workbench"

  def dir, do: Path.join(Workbench.root(), @dir)

  # --- inside the session ---

  @doc "Advertise the running session. Written only under the session lock."
  def advertise!(dir, port, node) do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    System.put_env("WORKBENCH_SESSION_ID", id)
    info = %{"id" => id, "pid" => System.pid(), "port" => port, "node" => Atom.to_string(node)}
    path = Path.join(dir, "session.json")
    File.write!(path <> ".tmp", JSON.encode!(info))
    File.rename!(path <> ".tmp", path)
    id
  end

  @doc "Block the session script until a remote `request_stop/1` is admitted."
  def await_stop do
    receive do
      {:stop_session, request} ->
        ref = Process.monitor(request)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :stopped
        after
          5_000 -> :stopped
        end
    end
  end

  @doc "Called remotely by `mix dev.stop`; the runner serializes it with admission."
  def request_stop(id), do: Scenarios.Runner.stop_session(id, self())

  # --- clients ---

  def info(dir \\ dir()) do
    with true <- locked?(dir),
         {:ok, data} <- File.read(Path.join(dir, "session.json")),
         {:ok, %{"id" => _, "node" => node, "port" => _} = info} <- JSON.decode(data) do
      Map.put(info, "node", String.to_atom(node))
    else
      _ -> nil
    end
  end

  @doc "Call a function inside the running session."
  def call(module, function, args, timeout \\ 15_000) do
    case info() do
      nil ->
        {:error, :not_running}

      %{"node" => node} ->
        attach!()
        :erpc.call(node, module, function, args, timeout)
    end
  catch
    :error, {:erpc, reason} -> {:error, reason}
  end

  defp attach! do
    unless Node.alive?() do
      name = :"workbench_cli_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = Node.start(name, name_domain: :longnames, hidden: true)
    end

    Node.set_cookie(:mycookie)
  end

  def locked?(dir \\ dir()) do
    lock = Path.join(dir, "session.lock")

    File.exists?(lock) and
      case System.cmd("flock", ["--nonblock", "--conflict-exit-code", "75", lock, "true"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> false
        {_, 75} -> true
        {_, status} -> raise "Cannot inspect session lock (exit #{status})"
      end
  end

  def describe do
    case info() do
      nil ->
        "No Workbench session is running."

      info ->
        state =
          case call(Scenarios.Runner, :snapshot, [], 2_000) do
            %{lifecycle: %{status: status}} -> "running · simulated devices #{status}"
            _ -> "unresponsive"
          end

        "Workbench #{state} at http://localhost:#{info["port"]} (PID #{info["pid"]}). Node: #{info["node"]}."
    end
  end

  def stop do
    case info() do
      nil ->
        :ok

      %{"id" => id} ->
        case call(__MODULE__, :request_stop, [id], 5_000) do
          :ok -> await_unlocked(System.monotonic_time(:millisecond) + 30_000)
          {:error, reason} when is_binary(reason) -> {:error, reason}
          _ -> {:error, "Shutdown outcome unknown. Run mix dev.status; do not replay."}
        end
    end
  end

  defp await_unlocked(deadline) do
    cond do
      not locked?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "Shutdown still in progress. Run mix dev.status."}

      true ->
        Process.sleep(100)
        await_unlocked(deadline)
    end
  end

  def conflict_message,
    do:
      describe() <>
        " Use mix dev.status or mix dev.stop. Never delete _build/workbench/session.lock."
end

defmodule Workbench.Session do
  @moduledoc """
  This checkout's `mix dev` session: a flock-held, uniquely named hidden node.
  Clients (Mix tasks, Pi) attach over distribution and call ordinary functions.
  """

  @dir "_build/workbench"
  @protocol 1
  # Deliberately small wire/admission contract, not a source freshness scanner.
  @manifest ~w(lib/workbench/session.ex lib/workbench/jobs.ex lib/scenarios/runner.ex
    sdk/lib/nerves_gate_sdk/backend.ex firmware/lib/nerves_gate/sdk_backend.ex)

  for path <- @manifest, do: @external_resource(Path.expand("../../#{path}", __DIR__))

  @compiled_inputs Map.new(@manifest, fn path ->
                     {path,
                      :crypto.hash(:sha256, File.read!(Path.expand("../../#{path}", __DIR__)))
                      |> Base.encode16()}
                   end)

  def manifest, do: @manifest

  def capture do
    value = %{compatibility() | inputs: @compiled_inputs}
    :persistent_term.put({__MODULE__, :compatibility}, value)
  end

  def compatibility(root \\ Workbench.root()) do
    %{
      protocol: @protocol,
      platform: File.read!(Path.join(root, "VERSION")) |> String.trim(),
      sdk: File.read!(Path.join(root, "sdk/VERSION")) |> String.trim(),
      inputs:
        Map.new(@manifest, fn path ->
          {path, :crypto.hash(:sha256, File.read!(Path.join(root, path))) |> Base.encode16()}
        end)
    }
  end

  def handshake do
    %{
      root: canonical_root(Workbench.root()),
      id: System.get_env("WORKBENCH_SESSION_ID"),
      compatibility: :persistent_term.get({__MODULE__, :compatibility}, nil),
      loaded_sdk: Application.spec(:nerves_gate_sdk, :vsn) |> to_string(),
      loaded_platform: Application.spec(:nerves_gate_workbench, :vsn) |> to_string()
    }
  end

  def canonical_root(root) do
    # pwd -P resolves checkout symlinks without guessing another session.
    {path, 0} = System.cmd("pwd", ["-P"], cd: Path.expand(root))
    String.trim(path)
  end

  def identity, do: Map.take(handshake(), [:root, :id, :compatibility])

  def validate(remote, expected, mutation? \\ false)

  def validate(
        %{root: _, id: _, compatibility: _} = remote,
        %{root: _, id: _, compatibility: _} = expected,
        mutation?
      ) do
    cond do
      remote.root != expected.root or remote.id != expected.id ->
        {:error,
         "Session identity changed or belongs to another checkout. Inspect mix dev.status."}

      mutation? and (not is_map(remote.compatibility) or not is_map(expected.compatibility)) ->
        {:error,
         "Session protocol is unavailable. Coordinate a Workbench restart; no operation admitted."}

      mutation? and
          (remote.compatibility != expected.compatibility or
             Map.get(remote, :loaded_sdk) != Map.get(expected.compatibility, :sdk) or
             Map.get(remote, :loaded_platform) != Map.get(expected.compatibility, :platform)) ->
        {:error,
         "Workbench protocol/SDK inputs are stale. Coordinate a Workbench restart; no operation admitted."}

      true ->
        :ok
    end
  end

  def validate(_, _, _),
    do: {:error, "Invalid session identity/contract; inspect mix dev.doctor."}

  def admit(expected) do
    remote = handshake()
    # Check both the client's contract and current disk inputs inside the owner.
    with :ok <- validate(remote, expected, true),
         :ok <- validate(remote, %{expected | compatibility: compatibility()}, true),
         do: :ok
  end

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

  @doc "Block the session script until a verified remote stop is admitted."
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
  def request_stop(id, expected), do: Scenarios.Runner.stop_session(id, self(), expected)

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
  def call(module, function, args, timeout \\ 15_000),
    do: invoke(module, function, args, timeout, false)

  def command(module, function, args, timeout \\ 15_000),
    do: invoke(module, function, args, timeout, true)

  defp invoke(module, function, args, timeout, mutation?) do
    case info() do
      nil ->
        {:error, :not_running}

      %{"node" => node, "id" => id} ->
        attach!()

        expected = %{
          root: canonical_root(Workbench.root()),
          id: id,
          compatibility: compatibility()
        }

        remote = :erpc.call(node, __MODULE__, :handshake, [], timeout)

        with :ok <- validate(remote, expected, mutation?),
             :ok <- observation_contract(remote, module, function),
             %{"node" => ^node, "id" => ^id} <- info() do
          :erpc.call(
            node,
            module,
            function,
            if(mutation?, do: args ++ [expected], else: args),
            timeout
          )
        else
          {:error, _} = error -> error
          _ -> {:error, "Session replaced during attachment; inspect mix dev.status."}
        end
    end
  catch
    :error, {:erpc, _} ->
      {:error,
       if(mutation?,
         do: "Admission/outcome unknown. Inspect mix dev.job and the target; do not resubmit.",
         else:
           "Workbench unavailable or uses an unsupported session protocol. Inspect mix dev.status."
       )}
  end

  # Handshake remains available to diagnose an unsupported session. Domain reads
  # require the published observation protocol, not legacy-state fallbacks.
  defp observation_contract(_, __MODULE__, :handshake), do: :ok
  defp observation_contract(%{compatibility: %{protocol: @protocol}}, _, _), do: :ok

  defp observation_contract(_, _, _),
    do:
      {:error,
       "Session observation protocol is unavailable/unsupported. Inspect mix dev.doctor and coordinate a restart."}

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
        case command(__MODULE__, :request_stop, [id], 5_000) do
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

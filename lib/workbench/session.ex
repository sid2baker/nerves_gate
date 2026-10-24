defmodule Workbench.Session do
  @moduledoc "Host-only identity, status and graceful shutdown of this checkout's mix dev session."

  @dir "_build/workbench"

  # The script owns the application and simulator wrapper. Wait until the HTTP
  # response process exits before taking its endpoint down; Connection: close on
  # the response makes this bounded even with an otherwise pooled HTTP client.
  def await_stop(dir) do
    phase(dir, :running)

    receive do
      {:stop_session, request} when is_pid(request) ->
        phase(dir, :stopping)
        ref = Process.monitor(request)

        receive do
          {:DOWN, ^ref, :process, ^request, _} -> :stopped
        after
          5_000 -> :stopped
        end
    end
  end

  # Written only under the session lock. A leftover file never establishes liveness.
  def prepare(dir, port) do
    info = %{
      "id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "pid" => System.pid(),
      "port" => port,
      "phase" => "starting"
    }

    write(dir, info)
    info["id"]
  end

  def phase(dir, phase) when phase in [:running, :stopping] do
    if info = read(dir), do: write(dir, Map.put(info, "phase", Atom.to_string(phase)))
    :ok
  end

  defp write(dir, info) do
    path = Path.join(dir, "session.json")
    File.write!(path <> ".tmp", JSON.encode!(info))
    File.rename!(path <> ".tmp", path)
  end

  defp read(dir) do
    with {:ok, data} <- File.read(Path.join(dir, "session.json")),
         {:ok, %{"id" => id, "pid" => pid, "port" => port, "phase" => phase} = info} <-
           JSON.decode(data),
         true <- is_binary(id) and byte_size(id) == 32,
         true <- is_binary(pid) and pid =~ ~r/\A[0-9]+\z/,
         true <- is_integer(port) and port in 1..65_535,
         true <- phase in ~w(starting running stopping) do
      Map.take(info, ~w(id pid port phase))
    else
      _ -> nil
    end
  end

  def locked?(dir \\ @dir) do
    lock = Path.join(dir, "session.lock")

    if File.exists?(lock) do
      case System.cmd("flock", ["--nonblock", "--conflict-exit-code", "75", lock, "true"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> false
        {_, 75} -> true
        {_, status} -> Mix.raise("Cannot inspect simulator session lock (exit #{status}).")
      end
    else
      false
    end
  end

  def status(dir \\ @dir) do
    if locked?(dir) do
      info = read(dir) || %{}
      state = api_state(dir)
      port = info["port"] || state["session_port"]
      url = if is_integer(port) and port in 1..65_535, do: "http://localhost:#{port}"

      %{
        status: status_kind(info, state),
        id: info["id"],
        pid: info["pid"],
        url: url,
        devices: get_in(state, ["lifecycle", "status"])
      }
    else
      %{status: :stopped}
    end
  end

  defp api_state(dir) do
    case connect(dir, 1_000) do
      {_, state} -> state
      nil -> %{}
    end
  end

  defp status_kind(info, state) do
    cond do
      info["phase"] == "stopping" -> :stopping
      info["phase"] == "starting" -> :starting
      map_size(state) > 0 and (info["id"] == nil or state["session_id"] == info["id"]) -> :running
      true -> :unresponsive
    end
  end

  def describe(%{status: :stopped}), do: "No simulator session is running."

  def describe(info) do
    owner = if info.pid, do: " (launcher PID #{info.pid})", else: ""
    url = if info.url, do: " at #{info.url}", else: ""
    devices = if info.devices, do: " Devices: #{info.devices}.", else: ""
    "Simulator session #{info.status}#{url}#{owner}.#{devices}"
  end

  def conflict_message do
    case status() do
      %{status: :stopped} ->
        "The previous simulator session has finished shutting down. Retry mix dev."

      info ->
        describe(info) <>
          " Use mix dev.status or mix dev.stop. Never delete _build/workbench/session.lock."
    end
  end

  # Keep credentials in the request client, never in status or diagnostic output.
  def connect(dir \\ @dir, timeout \\ 10_000) do
    {:ok, _} = Application.ensure_all_started(:req)

    client =
      Req.new(
        base_url: "http://localhost",
        unix_socket: Path.relative_to_cwd(Path.join(dir, "http.sock"), force: true),
        retry: false,
        redirect: false,
        connect_options: [timeout: 200],
        receive_timeout: timeout
      )

    case Req.get(client, url: "/api/state") do
      {:ok, %{status: 200, body: %{"session_port" => _}} = response} ->
        cookie =
          Enum.map_join(
            Req.Response.get_header(response, "set-cookie"),
            "; ",
            &hd(String.split(&1, ";", parts: 2))
          )

        headers = [cookie: cookie, "x-csrf-token": response.body["csrf_token"]]
        {Req.merge(client, headers: headers), response.body}

      _ ->
        nil
    end
  end

  def stop(dir \\ @dir) do
    case status(dir) do
      %{status: :stopped} -> :ok
      %{status: :stopping, id: id} -> await_stopped(dir, id, now() + 30_000)
      %{id: id} when is_binary(id) -> request_stop(dir, id)
      _ -> {:error, "This session has no control identity. Stop it from its original terminal."}
    end
  end

  defp request_stop(dir, id) do
    case connect(dir, 2_000) do
      {client, %{"session_id" => ^id}} ->
        # Never replay a shutdown request whose outcome is unknown.
        case Req.post(client, url: "/api/control", form: [session: "stop", session_id: id]) do
          {:ok, %{status: 200, body: %{"ok" => true}}} ->
            await_stopped(dir, id, now() + 30_000)

          {:ok, %{status: 200, body: %{"error" => error}}} when is_binary(error) ->
            {:error, error}

          _ ->
            {:error,
             "Shutdown outcome unknown. Inspect mix dev.status; do not replay automatically."}
        end

      {_, _} ->
        {:error, "Session identity changed. Inspect mix dev.status before trying again."}

      nil ->
        {:error,
         "Session API unavailable (starting or unresponsive). Use its original terminal; no process was killed."}
    end
  end

  defp await_stopped(dir, id, deadline) do
    info = read(dir)

    cond do
      not locked?(dir) ->
        :ok

      info && info["id"] != id ->
        {:error, "The old session stopped, but another session has started. Run mix dev.status."}

      now() >= deadline ->
        {:error,
         "Shutdown is still in progress or unresponsive. Run mix dev.status; no process was killed."}

      true ->
        Process.sleep(100)
        await_stopped(dir, id, deadline)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

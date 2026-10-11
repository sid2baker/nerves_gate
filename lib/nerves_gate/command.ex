defmodule NervesGate.Command do
  @moduledoc """
  Synchronous public acknowledgement over a Jido turn and its post-commit effect.

  Jido committing agent state is not a hardware acknowledgement. A temporary
  Erlang alias receives the effect result; a timeout means outcome unknown and
  does not authorize retrying a write. No caller handle enters agent state.
  """
  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  @doc "Check a domain-scoped optimistic token, never an authorization credential."
  def check_revision(nil, _), do: :ok
  def check_revision(expected, %{revision: expected}), do: :ok
  def check_revision(_, _), do: {:error, :stale_revision}

  @doc false
  def child(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  def call(server, type, params, context \\ %{}, timeout \\ 15_000)

  def call(server, type, params, context, timeout) when is_pid(server) do
    reply_to = :erlang.alias()
    monitor = Process.monitor(server)

    signal =
      Jido.Signal.new!(type, params, source: "/nerves_gate/commands", id: id())

    context = Map.merge(context, %{reply_to: reply_to, request_id: signal.id})

    try do
      with :ok <- Jido.AgentServer.await_ready(server),
           {:ok, agent} <-
             Jido.AgentServer.call(server, signal, context: context, timeout: timeout) do
        case agent.state.outcome do
          :pending -> await_result(signal.id, monitor, timeout)
          outcome -> outcome
        end
      end
    catch
      :exit, _ -> {:error, :outcome_unknown}
    after
      :erlang.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  def call(_, _, _, _, _), do: {:error, :outcome_unknown}

  def reply(%{reply_to: reply_to, request_id: id}, result) do
    send(reply_to, {:command_result, id, result})
    :ok
  end

  def reply(_, _) do
    :ok
  end

  defp await_result(id, monitor, timeout) do
    receive do
      {:command_result, ^id, result} -> result
      {:DOWN, ^monitor, :process, _, _} -> {:error, :outcome_unknown}
    after
      timeout -> {:error, :outcome_unknown}
    end
  end
end

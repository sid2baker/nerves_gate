defmodule Workbench.CLI.Diagnostics do
  @moduledoc "Read-only session/precondition diagnostics and owner-local operation lookup."
  alias Workbench.{CLI, Session}

  def doctor([]) do
    local = Session.compatibility()

    CLI.print(%{
      root: Session.canonical_root(Workbench.root()),
      expected: local,
      prerequisites: Simulator.Prerequisites.status(),
      networking_tool: System.find_executable("ip") != nil,
      management_network: Workbench.ManagementNetwork.status()
    })

    case Session.info() do
      nil ->
        IO.puts("No running session. Standalone builds and host checks remain available.")

      metadata ->
        CLI.print(metadata)

        case Session.call(Session, :handshake, []) do
          %{compatibility: _} = remote ->
            expected = %{
              root: Session.canonical_root(Workbench.root()),
              id: metadata["id"],
              compatibility: local
            }

            CLI.print(%{
              session: remote,
              mutation_preflight: Session.validate(remote, expected, true)
            })

            case Session.call(Scenarios.Runner, :snapshot, []) do
              %{lifecycle: lifecycle, blocked: blocked} ->
                CLI.print(%{
                  simulator: Map.take(lifecycle, [:status, :phase, :prepared, :reset_required]),
                  control_blocked: blocked
                })

              error ->
                CLI.print(error)
            end

          error ->
            CLI.print(error)
        end
    end
  end

  def doctor(_), do: Mix.raise("Usage: mix dev.doctor")

  def job([]) do
    CLI.print(Enum.map(CLI.call(Workbench.Jobs, :history), &observation/1))
    view = CLI.call(Scenarios.Runner, :snapshot)
    CLI.print(%{runs: view.runs, operations: view.operations})
  end

  def job([id]) do
    owner =
      cond do
        String.contains?(id, ":jobs:") -> Workbench.Jobs
        String.contains?(id, ":runner:") -> Scenarios.Runner
        true -> Mix.raise("Use the full owner-qualified ID from mix dev.job")
      end

    {:ok, operation} = CLI.call(owner, :fetch, [id])
    CLI.print(observation(operation))
  end

  def job(_), do: Mix.raise("Usage: mix dev.job [ID]")

  defp observation(%{review: review} = operation) when is_map(review),
    do: %{operation | review: Map.delete(review, :token)}

  defp observation(operation), do: operation
end

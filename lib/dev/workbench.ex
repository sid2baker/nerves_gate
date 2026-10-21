defmodule Dev.Workbench do
  @moduledoc "Shared UI/CLI coordination; QEMU admission stays owned by the simulator."
  def solution do
    case System.get_env("NERVES_GATE_SOLUTION") do
      nil ->
        nil

      path ->
        solution = Dev.Solution.load!(path)

        %{
          path: solution.path,
          platform: solution.settings.platform,
          warning: solution.warning,
          apps: Enum.map(solution.apps, &elem(&1, 0))
        }
    end
  end

  defdelegate stop_session(id), to: Dev.Operations
  defdelegate lifecycle(action), to: Dev.Operations
  defdelegate operate(kind, app, device), to: Dev.Operations, as: :start
end

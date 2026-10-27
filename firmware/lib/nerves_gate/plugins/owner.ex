defmodule NervesGate.Plugins.Owner do
  @moduledoc "Private activation fencing. ETS belongs to Plugins; resource ownership still belongs to the calling PID."
  @table __MODULE__

  def init do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok
  end

  def bind(artifact, generation) do
    tag = %{app: to_string(artifact.app), generation: generation}
    :ets.insert(@table, {{:generation, generation}, :active})
    Enum.each(artifact.apps, fn app -> :ets.insert(@table, {{:app, app.app}, tag}) end)
    tag
  end

  def quiesce(tag), do: :ets.insert(@table, {{:generation, tag.generation}, :quiescing})
  def revoke(tag), do: :ets.delete(@table, {:generation, tag.generation})

  def resolve(pid, mode \\ :active) do
    with {:ok, app} <- :application.get_application(pid),
         [{{:app, ^app}, tag}] <- :ets.lookup(@table, {:app, app}),
         true <- valid?(tag, mode) do
      {:ok, tag}
    else
      _ -> {:error, :application_not_running}
    end
  rescue
    ArgumentError -> {:error, :application_not_running}
  end

  def valid?(owner, mode \\ :active)

  def valid?(%{generation: generation}, mode) do
    case :ets.lookup(@table, {:generation, generation}) do
      [{{:generation, ^generation}, :active}] -> true
      [{{:generation, ^generation}, :quiescing}] -> mode == :release
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def valid?(_, _), do: false

  def matches?(pid, tag, mode \\ :active), do: resolve(pid, mode) == {:ok, tag}
end

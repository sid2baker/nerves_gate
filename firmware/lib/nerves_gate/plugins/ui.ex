defmodule NervesGate.Plugins.UI do
  @moduledoc "Optional plugin-owned LiveComponents. Local OTP process groups let cleanup outlive a Plugins controller restart."
  @scope __MODULE__

  def child_spec(_) do
    %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}
  end

  def component(artifact) do
    main = Enum.find(artifact.apps, &(&1.app == artifact.app))
    component = main.env[:nerves_gate_ui]

    cond do
      component == nil ->
        {:ok, nil}

      component in artifact.modules and function_exported?(component, :__live__, 0) and
          function_exported?(component, :render, 1) ->
        case component.__live__() do
          %{kind: :component} -> {:ok, component}
          _ -> {:error, :invalid_app_ui}
        end

      true ->
        {:error, :invalid_app_ui}
    end
  catch
    _, _ -> {:error, :invalid_app_ui}
  end

  def join(app, pid) do
    :pg.join(@scope, app, pid)
  catch
    :exit, _ -> {:error, :ui_unavailable}
  end

  def close(app) do
    members = :pg.get_local_members(@scope, app)
    await_closed(members)
  end

  def close_all do
    if Process.whereis(@scope) do
      @scope
      |> :pg.which_groups()
      |> Enum.flat_map(&:pg.get_local_members(@scope, &1))
      |> Enum.uniq()
      |> await_closed()
    else
      :ok
    end
  end

  defp await_closed(members) do
    monitors = Enum.map(members, &{&1, Process.monitor(&1)})
    Enum.each(members, &send(&1, :app_ui_close))
    deadline = System.monotonic_time(:millisecond) + 5_000

    result =
      Enum.reduce_while(monitors, :ok, fn {pid, ref}, :ok ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> {:cont, :ok}
        after
          remaining -> {:halt, {:error, :ui_cleanup_pending}}
        end
      end)

    Enum.each(monitors, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)
    result
  end
end

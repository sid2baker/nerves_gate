defmodule NervesGate.Plugins.Loader do
  @moduledoc "Verified cold OTP activation and one fail-closed unload path."
  alias NervesGate.Plugins.{Artifact, Owner, UI}

  def prepare(app, version, entries, previous) do
    with {:ok, artifact, package} <- Artifact.load(app, version, entries[app].artifacts[version]),
         :ok <- Artifact.validate(package, entries, app, previous),
         false <-
           Enum.any?(artifact.paths, fn path ->
             String.to_charlist(path) in :code.get_path() and
               not (previous && path in previous.paths)
           end) do
      {:ok, artifact, package}
    else
      true -> {:error, :code_path_conflict}
      error -> error
    end
  end

  def activate(activation, package, checkpoint) do
    activation = %{activation | phase: :loading}

    with :ok <- checkpoint.(activation),
         :ok <- paths(activation.artifact.paths),
         :ok <- specs(activation.artifact.apps),
         :ok <- preload(activation.artifact, package.files),
         {:ok, component} <- UI.component(activation.artifact) do
      start_private(
        Map.merge(activation, %{phase: :starting, ui: component}),
        package,
        checkpoint
      )
    else
      {:error, reason} -> {:error, reason, activation}
    end
  end

  defp start_private(activation, package, checkpoint) do
    with :ok <- checkpoint.(activation),
         {:ok, started} <- Application.ensure_all_started(activation.artifact.app) do
      verify(%{activation | started: started, phase: :verifying}, package, checkpoint)
    else
      _ -> {:error, :application_start_failed, activation}
    end
  end

  defp verify(activation, package, checkpoint) do
    with :ok <- checkpoint.(activation),
         :ok <- health_check(package.main.env[:nerves_gate_health_check]) do
      {:ok, %{activation | phase: :running}}
    else
      {:error, reason} -> {:error, reason, activation}
    end
  end

  def present?(artifact) do
    Enum.any?(artifact.paths, &(String.to_charlist(&1) in :code.get_path())) or
      Enum.any?(artifact.modules, fn module ->
        case :code.is_loaded(module) do
          {:file, path} -> Artifact.owns_module?(artifact, module, path)
          _ -> false
        end
      end)
  end

  def unload(activation) do
    artifact = activation.artifact

    with :ok <- UI.close(to_string(artifact.app)),
         :ok <- private_specs?(artifact),
         :ok <- stop_apps(artifact, activation.started),
         :ok <- drain_activation(activation),
         :ok <- unload_specs(artifact.apps),
         :ok <- purge_modules(artifact) do
      remove_paths(artifact.paths)
    end
  end

  # Before OTP startup there is no managed process that can acquire SDK resources.
  defp drain_activation(%{phase: phase}) when phase in [:prepared, :loading], do: :ok
  defp drain_activation(activation), do: drain(activation.owner || :inactive)

  def drain(tag) do
    Enum.reduce_while(
      [NervesGate.SDKBackend, NervesGate.Network],
      :ok,
      fn domain, :ok ->
        case GenServer.call(domain, {:drain_generation, tag}, 75_000) do
          :ok -> {:cont, :ok}
          _ -> {:halt, {:error, :generation_cleanup_pending}}
        end
      end
    )
  catch
    :exit, _ -> {:error, :generation_cleanup_pending}
  end

  def stale?(owner, :inactive), do: not Owner.valid?(owner, :release)
  def stale?(owner, expected), do: owner == expected

  defp paths(paths) do
    reduce(paths, fn path ->
      case :code.add_patha(String.to_charlist(path)) do
        true -> :ok
        _ -> {:error, :code_path_failed}
      end
    end)
  end

  defp specs(apps),
    do: reduce(apps, fn app -> :application.load({:application, app.app, app.spec}) end)

  defp preload(artifact, files) do
    reduce(artifact.modules, &load_module(artifact, &1, files))
  end

  defp load_module(artifact, module, files) do
    {path, bytes} = Artifact.beam(artifact, module, files)

    if :code.is_loaded(module) == false do
      case :code.load_binary(module, String.to_charlist(path), bytes) do
        {:module, ^module} -> :ok
        _ -> {:error, :module_load_failed}
      end
    else
      {:error, :module_conflict}
    end
  end

  defp health_check(nil), do: :ok

  defp health_check({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    task =
      Task.Supervisor.async(NervesGate.PluginTasks, fn ->
        try do
          apply(module, function, args)
        catch
          _, _ -> :health_check_failed
        end
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      nil -> {:error, :health_check_timeout}
      _ -> {:error, :health_check_failed}
    end
  end

  defp health_check(_), do: {:error, :invalid_health_check}

  defp private_specs?(artifact) do
    if Enum.all?(artifact.apps, fn app ->
         Application.spec(app.app) == nil or
           (to_string(Application.spec(app.app, :vsn)) == app.version and
              Enum.sort(Application.spec(app.app, :modules) || []) == Enum.sort(app.modules))
       end), do: :ok, else: {:error, :application_conflict}
  end

  defp stop_apps(artifact, started) do
    private = MapSet.new(artifact.apps, & &1.app)
    order = Enum.reverse(started ++ dependency_order(artifact.apps)) |> Enum.uniq()

    order
    |> Enum.filter(&MapSet.member?(private, &1))
    |> reduce(fn name ->
      case Application.stop(name) do
        :ok -> :ok
        {:error, {:not_started, ^name}} -> :ok
        _ -> {:error, :application_stop_failed}
      end
    end)
  end

  defp dependency_order(apps) do
    by_name = Map.new(apps, &{&1.app, &1})

    Enum.reduce(apps, [], fn app, order -> visit(app.app, by_name, order, []) end)
    |> Enum.reverse()
  end

  defp visit(name, apps, order, visiting) do
    if name in order or not Map.has_key?(apps, name) or name in visiting do
      order
    else
      visiting = [name | visiting]
      [name | Enum.reduce(apps[name].applications, order, &visit(&1, apps, &2, visiting))]
    end
  end

  defp unload_specs(apps) do
    reduce(apps, fn app ->
      case Application.unload(app.app) do
        :ok -> :ok
        {:error, {:not_loaded, _}} -> :ok
        _ -> {:error, :application_unload_failed}
      end
    end)
  end

  defp purge_modules(artifact) do
    reduce(artifact.modules, &purge_module(artifact, &1))
  end

  defp purge_module(artifact, module) do
    case :code.is_loaded(module) do
      false -> soft_purge(module)
      {:file, path} -> delete_owned(artifact, module, path)
    end
  end

  defp delete_owned(artifact, module, path) do
    with true <- Artifact.owns_module?(artifact, module, path),
         :ok <- soft_purge(module),
         true <- :code.delete(module) do
      soft_purge(module)
    else
      false -> {:error, :module_conflict}
      error -> error
    end
  end

  defp soft_purge(module) do
    if :code.soft_purge(module), do: :ok, else: {:error, :module_busy}
  end

  defp remove_paths(paths) do
    Enum.each(paths, &:code.del_path(String.to_charlist(&1)))

    if Enum.any?(paths, &(String.to_charlist(&1) in :code.get_path())),
      do: {:error, :code_path_busy},
      else: :ok
  end

  defp reduce(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end

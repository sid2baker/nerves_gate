defmodule NervesGate.Apps do
  @moduledoc """
  Administrative lifecycle for trusted OTP applications on SD.

  Code lives under `/mnt/apps/apps/<app>/<version>` and application data under
  `/mnt/apps/data/<app>`. Only enabled/active/previous selection is persisted in
  `/data/nerves_gate/apps.term`. Install does not start an application. Upgrades
  are cold stop/start with a health check and rollback; this is not a sandbox or
  an OTP hot-code upgrade service. Uninstall preserves application data.
  """
  use GenServer
  alias NervesGate.Storage
  alias NervesGateSDK.Package

  @timeout 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def install(path), do: GenServer.call(__MODULE__, {:install, path}, @timeout)
  def list, do: GenServer.call(__MODULE__, :list)
  def start(app), do: GenServer.call(__MODULE__, {:start, app}, @timeout)
  def stop(app), do: GenServer.call(__MODULE__, {:stop, app}, @timeout)
  def restart(app), do: GenServer.call(__MODULE__, {:restart, app}, @timeout)
  def upgrade(path), do: GenServer.call(__MODULE__, {:upgrade, path}, @timeout)
  def rollback(app), do: GenServer.call(__MODULE__, {:rollback, app}, @timeout)
  def uninstall(app), do: GenServer.call(__MODULE__, {:uninstall, app}, @timeout)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    file = Application.get_env(:nerves_gate, :apps_metadata, "/data/nerves_gate/apps.term")

    with {:ok, entries} <- read_metadata(file) do
      state = %{file: file, entries: entries, running: %{}, errors: %{}, available?: false}
      {:ok, state, {:continue, :restore}}
    end
  end

  @impl true
  def handle_continue(:restore, state) do
    Process.send_after(self(), :storage, 1_000)
    {:noreply, restore(state)}
  end

  @impl true
  def handle_call(:list, _, state) do
    apps =
      for {app, entry} <- state.entries do
        Map.merge(entry, %{
          app: app,
          running?: Map.has_key?(state.running, app),
          versions: versions(app),
          error: state.errors[app]
        })
      end

    {:reply, {:ok, Enum.sort_by(apps, & &1.app)}, state}
  end

  def handle_call({:install, path}, _, state) do
    {reply, state} = install_package(path, state)
    {:reply, reply, state}
  end

  def handle_call({:upgrade, path}, _, state) do
    with {:ok, package} <- Package.read(path),
         true <- Map.has_key?(state.entries, to_string(package.app)),
         {{:ok, _}, installed} <- install_package(path, state) do
      {reply, next} = switch(to_string(package.app), package.version, installed)
      {:reply, reply, next}
    else
      false -> {:reply, {:error, :not_installed}, state}
      {{:error, reason}, next} -> {:reply, {:error, reason}, next}
      error -> {:reply, error, state}
    end
  end

  def handle_call({operation, app}, _, state)
      when operation in [:start, :stop, :restart, :rollback, :uninstall] do
    if Package.valid_name?(app) and Map.has_key?(state.entries, to_string(app)) do
      {reply, next} = command(operation, to_string(app), state)
      {:reply, reply, next}
    else
      {:reply, {:error, :not_installed}, state}
    end
  end

  @impl true
  def handle_info(:storage, state) do
    Process.send_after(self(), :storage, 1_000)
    Storage.mount()
    available? = match?({:ok, _}, Storage.root())

    next =
      cond do
        available? and not state.available? -> restore(state)
        not available? -> Enum.reduce(Map.keys(state.running), state, &halt/2)
        true -> state
      end

    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    next =
      Enum.reduce(next.running, next, fn {app, info}, acc ->
        if MapSet.member?(started, info.package.app) do
          acc
        else
          acc = halt(app, acc)
          %{acc | errors: Map.put(acc.errors, app, :application_stopped)}
        end
      end)

    {:noreply, %{next | available?: available?}}
  end

  # Trapping exits lets terminate/2 stop apps; System.cmd ports also report exits.
  def handle_info({:EXIT, port, _}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    for {app, _} <- state.running, do: halt(app, state)
    :ok
  end

  defp command(:start, app, %{running: running} = state) when is_map_key(running, app),
    do: {:ok, state}

  defp command(:start, app, state) do
    with {:ok, started} <- launch(app, state.entries[app].active_version, state),
         {:ok, saved} <- save_entry(started, app, %{state.entries[app] | enabled: true}) do
      {:ok, saved}
    else
      {:error, reason, next} -> {{:error, reason}, halt(app, next)}
    end
  end

  defp command(:stop, app, state) do
    # Persist the user's intent before stopping; a failed write must not silently
    # turn into an enabled application after a reboot.
    case save_entry(state, app, %{state.entries[app] | enabled: false}) do
      {:ok, next} -> {:ok, halt(app, next)}
      {:error, reason, next} -> {{:error, reason}, next}
    end
  end

  defp command(:restart, app, state), do: command(:start, app, halt(app, state))

  defp command(:rollback, app, state) do
    case state.entries[app].previous_version do
      nil -> {{:error, :no_previous_version}, state}
      version -> switch(app, version, state)
    end
  end

  defp command(:uninstall, app, state) do
    with {:ok, root} <- Storage.apps_dir(),
         :ok <- persist(state.file, Map.delete(state.entries, app)) do
      next = halt(app, state)

      result =
        case File.rm_rf(Path.join(root, app)) do
          {:ok, _} -> :ok
          {:error, reason, _} -> {:error, reason}
        end

      {result,
       %{next | entries: Map.delete(next.entries, app), errors: Map.delete(next.errors, app)}}
    else
      error -> {error, state}
    end
  end

  defp install_package(path, state) do
    with {:ok, root} <- Storage.apps_dir(),
         {:ok, package} <- Package.read(path),
         app = to_string(package.app),
         :ok <- validate(package, app, state),
         {:ok, directory} <- Storage.directory(root, app),
         destination = Path.join(directory, package.version),
         # Never replace a selected version. Other copies (a failed upgrade, or
         # files left after /data was reset) are unregistered and replaceable.
         false <- in_use?(state.entries[app], package.version),
         {:ok, _} <- File.rm_rf(destination),
         stage = Path.join(directory, ".install-#{System.unique_integer([:positive])}"),
         :ok <- Package.extract(package, stage),
         :ok <- rename(stage, destination) do
      register(state, app, package, destination)
    else
      true -> {{:error, :already_installed}, state}
      error -> {error, state}
    end
  end

  defp rename(stage, destination) do
    with {:error, _} = error <- File.rename(stage, destination) do
      File.rm_rf(stage)
      error
    end
  end

  defp register(state, app, package, destination) do
    entry =
      Map.get(state.entries, app, %{
        enabled: false,
        active_version: package.version,
        previous_version: nil
      })

    case save_entry(state, app, entry) do
      {:ok, next} ->
        {{:ok, %{app: package.app, version: package.version}}, next}

      {:error, reason, next} ->
        File.rm_rf(destination)
        {{:error, reason}, next}
    end
  end

  defp in_use?(nil, _version), do: false

  defp in_use?(entry, version),
    do: version in [entry.active_version, entry.previous_version]

  defp switch(app, version, state) do
    # Validate before stopping working code. Commit selection only after the
    # new application has started and passed its bounded health check.
    with false <- version == state.entries[app].active_version,
         {:ok, package, _} <- read_package(app, version),
         :ok <- validate(package, app, state) do
      switch_validated(app, version, state)
    else
      true -> {{:error, :already_active}, state}
      error -> {error, state}
    end
  end

  defp switch_validated(app, version, state) do
    old = state.entries[app]
    was_running? = Map.has_key?(state.running, app)
    stopped = halt(app, state)
    entry = %{old | enabled: true, active_version: version, previous_version: old.active_version}

    with {:ok, started} <- launch(app, version, stopped),
         {:ok, saved} <- save_entry(started, app, entry) do
      {:ok, saved}
    else
      {:error, reason, next} -> rollback_failed(app, old, was_running?, reason, next)
    end
  end

  defp rollback_failed(app, old, was_running?, reason, state) do
    state = halt(app, state)
    result = if was_running?, do: launch(app, old.active_version, state), else: {:ok, state}

    case result do
      {:ok, next} ->
        error = {:rolled_back, reason}
        {{:error, error}, %{next | errors: Map.put(next.errors, app, error)}}

      {:error, rollback_reason, next} ->
        error = {:rollback_failed, reason, rollback_reason}
        {{:error, error}, %{next | errors: Map.put(next.errors, app, error)}}
    end
  end

  defp launch(app, _version, %{running: running} = state) when is_map_key(running, app),
    do: {:ok, state}

  defp launch(app, version, state) do
    with {:ok, package, directory} <- read_package(app, version),
         :ok <- validate(package, app, state) do
      paths = Enum.map(package.apps, &Path.join([directory, &1.root, "ebin"]))
      info = %{package: Map.delete(package, :files), paths: paths, started: []}
      next = put_in(state.running[app], info)

      case start_package(app, package, paths, next) do
        {:ok, next} -> {:ok, next}
        {:error, reason, next} -> {:error, reason, halt(app, next)}
        {:error, reason} -> {:error, reason, halt(app, next)}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_package(app, package, paths, state) do
    with :ok <- add_paths(paths),
         :ok <- load_apps(package.apps),
         {:ok, started} <- Application.ensure_all_started(package.app),
         next = put_in(state.running[app].started, started),
         {:ok, next} <- healthy(package, next) do
      {:ok, %{next | errors: Map.delete(next.errors, app)}}
    end
  end

  defp healthy(package, state) do
    case health_check(package.main.env[:nerves_gate_health_check]) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp health_check(nil), do: :ok

  defp health_check({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    task =
      Task.Supervisor.async_nolink(NervesGate.AppTasks, fn -> apply(module, function, args) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      {:ok, _} -> {:error, :health_check_failed}
      {:exit, _} -> {:error, :health_check_failed}
      nil -> {:error, :health_check_timeout}
    end
  end

  defp health_check(_), do: {:error, :invalid_health_check}

  defp halt(app, state) do
    case Map.pop(state.running, app) do
      {nil, _} ->
        state

      {info, running} ->
        unload(info)
        %{state | running: running}
    end
  end

  # Never stop platform dependencies. Private dependencies belong solely to this
  # package, and cannot be shared with another installed app.
  defp unload(info) do
    names = MapSet.new(info.package.apps, & &1.app)
    order = Enum.reverse(info.started, Enum.map(info.package.apps, & &1.app))
    for name <- Enum.uniq(order), MapSet.member?(names, name), do: Application.stop(name)

    for entry <- info.package.apps do
      Application.unload(entry.app)
      Enum.each(entry.modules, &purge/1)
    end

    Enum.each(info.paths, &:code.del_path(String.to_charlist(&1)))
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp validate(package, owner, state) do
    own =
      case state.running[owner] do
        nil -> []
        info -> Enum.map(info.package.apps, & &1.app)
      end

    installed = Map.drop(Package.installed(), own)

    reserved =
      state.entries
      |> Map.delete(owner)
      |> Enum.reduce(installed, fn {app, entry}, acc -> reserve(acc, app, entry) end)

    Package.validate(package, reserved, to_string(Application.spec(:nerves_gate_sdk, :vsn)))
  end

  # Installed applications keep their names and modules, even while stopped.
  defp reserve(reserved, app, entry) do
    case read_package(app, entry.active_version) do
      {:ok, other, _} -> Enum.reduce(other.apps, reserved, &Map.put(&2, &1.app, &1))
      _ -> reserved
    end
  end

  defp read_package(app, version) do
    with {:ok, root} <- Storage.apps_dir(),
         directory = Path.join([root, app, version]),
         {:ok, package} <- Package.read_directory(directory),
         true <- to_string(package.app) == app and package.version == version do
      {:ok, package, directory}
    else
      false -> {:error, :invalid_package}
      error -> error
    end
  end

  defp add_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case :code.add_patha(String.to_charlist(path)) do
        true -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_apps(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case :application.load({:application, app.app, app.spec}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp restore(state) do
    available? = match?({:ok, _}, Storage.root())

    if available? do
      enabled = for {app, %{enabled: true} = entry} <- state.entries, do: {app, entry}
      Enum.reduce(enabled, %{state | available?: true}, &restore_app/2)
    else
      %{state | available?: false}
    end
  end

  defp restore_app({app, entry}, state) do
    case launch(app, entry.active_version, state) do
      {:ok, next} -> next
      {:error, reason, next} -> %{next | errors: Map.put(next.errors, app, reason)}
    end
  end

  defp versions(app) do
    with {:ok, root} <- Storage.apps_dir(), {:ok, names} <- File.ls(Path.join(root, app)) do
      names |> Enum.filter(&Package.valid_version?/1) |> Enum.sort()
    else
      _ -> []
    end
  end

  defp save_entry(state, app, entry) do
    entries = Map.put(state.entries, app, entry)

    case persist(state.file, entries) do
      :ok -> {:ok, %{state | entries: entries}}
      {:error, reason} -> {:error, {:metadata_write, reason}, state}
    end
  end

  defp persist(file, entries) do
    temp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(temp, :erlang.term_to_binary(entries), [:binary, :sync]) do
      File.rename(temp, file)
    end
  end

  defp read_metadata(file) do
    case File.read(file) do
      {:ok, bytes} ->
        entries = :erlang.binary_to_term(bytes, [:safe])

        if is_map(entries) and Enum.all?(entries, &valid_entry?/1),
          do: {:ok, entries},
          else: {:stop, :invalid_app_metadata}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:stop, {:app_metadata, reason}}
    end
  rescue
    # binary_to_term/2 rejects corrupt or unsafe terms.
    ArgumentError -> {:stop, :invalid_app_metadata}
  end

  defp valid_entry?({app, %{enabled: enabled, active_version: version} = entry})
       when is_binary(app) and is_boolean(enabled) and map_size(entry) == 3 do
    previous = Map.get(entry, :previous_version, :missing)

    Package.valid_name?(app) and Package.valid_version?(version) and
      (is_nil(previous) or Package.valid_version?(previous))
  end

  defp valid_entry?(_), do: false
end

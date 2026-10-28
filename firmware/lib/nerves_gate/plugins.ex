defmodule NervesGate.Plugins do
  @moduledoc "Serialized cold lifecycle for firmware-bundled plugins and development artifacts. Trusted OTP code, not a sandbox."
  use GenServer
  alias NervesGate.Plugins.{Artifact, Assignments, Bundled, Loader, Metadata, Owner, UI}
  alias NervesGate.Storage
  alias NervesGateSDK.Package
  @timeout 190_000
  @budget 180_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def install(path), do: command({:install, path})
  def install_new(path, expected), do: command({:install_new, path, expected})
  def list, do: GenServer.call(__MODULE__, :list)
  def hardware, do: GenServer.call(__MODULE__, :hardware)
  def resources, do: GenServer.call(__MODULE__, :resources)

  @doc false
  def authorize_port(pid, port), do: GenServer.call(__MODULE__, {:authorize_port, pid, port})

  def assign_port(port, enabled, plugin, stop_confirmed \\ false, expected \\ nil),
    do: command({:assign_port, port, enabled, plugin, stop_confirmed, expected})

  @doc false
  def mount_ui(app), do: GenServer.call(__MODULE__, {:mount_ui, app})
  def start(app), do: command({:start, app})
  def stop(app), do: command({:stop, app})
  def restart(app), do: command({:restart, app})
  def upgrade(path), do: command({:upgrade, path})
  def rollback(app), do: command({:rollback, app})
  def select(app, version), do: command({:select, app, version})
  def uninstall(app), do: command({:uninstall, app})
  defp command(request), do: GenServer.call(__MODULE__, request, @timeout)

  @doc "Read-only current device prerequisites for a reviewed new-plugin install."
  def install_review(%{"plugin" => plugin, "platform" => platform}) do
    storage = Storage.commissioning()
    {:ok, plugins} = list()
    info = NervesGate.System.maintenance_info()

    installed =
      Map.new(Application.loaded_applications(), fn {name, _, version} ->
        {to_string(name), to_string(version)}
      end)

    %{
      product: info.product,
      target: info.target,
      firmware: info.version,
      source_revision: info.source_revision,
      serial: info.serial,
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
      sdk_version: to_string(Application.spec(:nerves_gate_sdk, :vsn)),
      storage_ready: storage.ready,
      card_id: storage.card_id,
      installed: Enum.any?(plugins, &(&1.app == plugin)),
      platform_compatible:
        Enum.all?(platform, fn [name, version] -> installed[name] == version end)
    }
  end

  @doc "Execute one reviewed install; never retry an uncertain outcome."
  def install_reviewed(path, expected) do
    %{outcome: reviewed_outcome(install_new(path, expected), expected)}
  catch
    _, _ -> %{outcome: "unknown"}
  after
    if is_binary(path) and
         Regex.match?(~r|\A/tmp/nerves-gate-plugin-[a-f0-9]{32}/plugin\.ez\z|, path) do
      File.rm(path)
      File.rmdir(Path.dirname(path))
    end
  end

  defp reviewed_outcome({:ok, _}, expected) do
    {:ok, apps} = list()

    if Enum.any?(
         apps,
         &(&1.app == expected.plugin and &1.active_version == expected.version and
             &1.sha256 == expected.sha256 and not &1.enabled and not &1.running?)
       ), do: "installed_stopped", else: "unknown"
  end

  defp reviewed_outcome({:error, _}, _), do: "rejected"
  defp reviewed_outcome(_, _), do: "unknown"

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    Owner.init()
    file = Application.get_env(:nerves_gate, :plugins_metadata, "/data/nerves_gate/plugins.term")

    {entries, blocked} = initial_entries(file)

    hardware_file =
      Application.get_env(:nerves_gate, :hardware_assignments, "/data/nerves_gate/hardware.term")

    {assignments, assignment_error} =
      case Assignments.read(hardware_file) do
        {:ok, ports} -> {ports, nil}
        {:error, reason} -> {%{}, reason}
      end

    state = %{
      hardware_file: hardware_file,
      assignments: assignments,
      assignment_error: assignment_error,
      file: file,
      entries: entries,
      running: %{},
      errors: %{},
      job: nil,
      blocked: blocked,
      blocked_app: nil,
      epoch: make_ref(),
      sequence: Enum.reduce(entries, 0, fn {_, entry}, n -> max(n, entry.generation) end),
      restored?: false,
      available?: false,
      storage_identity: nil
    }

    send(self(), :storage)
    {:ok, state}
  end

  defp initial_entries(file) do
    obsolete =
      file == "/data/nerves_gate/plugins.term" and File.exists?("/data/nerves_gate/apps.term")

    if obsolete do
      {%{}, :obsolete_application_metadata}
    else
      with {:ok, entries} <- Metadata.read(file),
           {:ok, bundled} <- Bundled.entries(),
           {:ok, merged} <- Bundled.merge(entries, bundled) do
        {merged, nil}
      else
        {:error, reason} -> {%{}, reason}
      end
    end
  end

  @impl true
  def handle_call(:list, _, %{blocked: blocked} = state)
      when blocked in [
             :invalid_app_metadata,
             :obsolete_application_metadata,
             :firmware_artifact_conflict
           ],
      do: {:reply, {:error, blocked}, state}

  def handle_call(:list, _, state) do
    entries =
      for {app, entry} <- state.entries do
        %{
          app: app,
          enabled: entry.enabled,
          active_version: entry.active_version,
          previous_version: entry.previous_version,
          sha256: entry.artifacts[entry.active_version].sha256,
          versions: Enum.sort(Map.keys(entry.artifacts)),
          generation: entry.generation,
          running?: match?(%{phase: :running}, state.running[app]),
          ui?: state.running[app] != nil and Map.get(state.running[app], :ui) != nil,
          operation: state.running[app] && state.running[app].phase,
          bundled?: firmware_entry?(entry),
          available_version: Bundled.version(app),
          error: state.errors[app] || state.blocked || missing_selection(app, entry)
        }
      end

    {:reply, {:ok, Enum.sort_by(entries, & &1.app)}, state}
  end

  def handle_call(:hardware, _, state) do
    {:reply,
     %{
       ports: state.assignments,
       error: state.assignment_error || state.blocked,
       capabilities: capabilities(state),
       plugins:
         Map.new(state.entries, fn {app, _} ->
           {app, if(Map.has_key?(state.running, app), do: :running, else: :stopped)}
         end),
       operation: state.job != nil
     }, state}
  end

  def handle_call({:authorize_port, pid, port}, _, state) do
    result =
      with nil <- state.assignment_error || state.blocked,
           {:ok, owner} <- Owner.resolve(pid),
           %{enabled: true, plugin: plugin} when plugin == owner.app <- state.assignments[port],
           true <- Assignments.kind(port) in Map.get(capabilities(state), plugin, []) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :hardware_not_assigned}
      end

    {:reply, result, state}
  end

  def handle_call(:resources, {pid, _}, state) do
    with nil <- state.assignment_error,
         {:ok, owner} <- Owner.resolve(pid) do
      resources =
        for port <- NervesGate.Hardware.inventory(),
            %{enabled: true, plugin: plugin} <- [state.assignments[port.name]],
            plugin == owner.app,
            kind = Assignments.kind(port.name),
            kind in Map.get(capabilities(state), plugin, []) do
          %NervesGateSDK.Hardware.Port{
            id: port.name,
            kind: kind,
            present?: port.present,
            path: Map.get(port, :path),
            interface: if(kind in [:can, :ethernet], do: port.name)
          }
        end

      {:reply, {:ok, resources}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :hardware_assignments_unavailable}, state}
    end
  end

  def handle_call({:mount_ui, app}, {pid, _}, state) do
    with nil <- state.blocked,
         nil <- state.job,
         %{phase: :running} = activation <- state.running[app],
         true <- Owner.valid?(activation.owner),
         component when not is_nil(component) <- Map.get(activation, :ui),
         :ok <- UI.join(app, pid) do
      {:reply, {:ok, component, self()}, state}
    else
      _ -> {:reply, {:error, :ui_unavailable}, state}
    end
  end

  def handle_call({:worker, op, request}, {pid, _}, %{job: %{op: op, task: %{pid: pid}}} = state),
    do: worker_call(request, state)

  def handle_call({:worker, _, _}, _, state), do: {:reply, {:error, :stale_operation}, state}

  def handle_call({:storage_setup, action, card_id, confirmation}, _, state) do
    if state.blocked != nil or state.job != nil or
         Enum.any?(state.entries, fn {_, entry} -> not firmware_entry?(entry) end) or
         map_size(state.running) != 0 do
      {:reply,
       {:error,
        %{
          code: "plugins_installed",
          message:
            "Application ownership is present or unresolved. Do not format or skip storage."
        }}, state}
    else
      {:reply, Storage.admit(action, card_id, confirmation), state}
    end
  end

  def handle_call(_, _, %{job: job} = state) when not is_nil(job),
    do: {:reply, {:error, :operation_in_progress}, state}

  def handle_call(request, from, state) do
    cond do
      state.blocked && not recovery?(request, state.blocked_app) ->
        {:reply, {:error, :plugins_blocked}, state}

      not (state.restored? and state.available?) and not match?({:stop, _}, request) ->
        {:reply, {:error, :plugins_not_ready}, state}

      true ->
        admit(request, from, state)
    end
  end

  defp admit(request, from, state), do: {:noreply, begin_work(request, from, state)}

  defp recovery?({:stop, app}, blocked) when is_binary(app) or is_atom(app),
    do: to_string(app) == blocked

  defp recovery?(_, _), do: false

  defp worker_call({:assignments, ports}, %{blocked: nil, assignment_error: nil} = state) do
    case Assignments.persist(state.hardware_file, ports) do
      :ok ->
        NervesGate.Observations.put(
          ["hardware", "assignments"],
          System.unique_integer([:positive])
        )

        {:reply, :ok, %{state | assignments: ports}}

      {:error, :metadata_commit_unknown} = error ->
        {:reply, error, %{state | assignment_error: :metadata_commit_unknown}}

      error ->
        {:reply, error, state}
    end
  end

  defp worker_call({:assignments, _}, state),
    do: {:reply, {:error, :hardware_assignments_unavailable}, state}

  defp worker_call(:check_storage, %{blocked: nil} = state),
    do: {:reply, storage_check(state.job), state}

  defp worker_call(:check_storage, state), do: {:reply, {:error, :plugins_blocked}, state}

  defp worker_call({:storage_identity, identity}, state),
    do: {:reply, :ok, %{state | job: Map.put(state.job, :storage_identity, identity)}}

  defp worker_call({:bind, artifact}, %{blocked: nil} = state) do
    sequence = state.sequence + 1
    owner = Owner.bind(artifact, {state.epoch, sequence})
    activation = %{artifact: artifact, owner: owner, started: [], phase: :prepared, ui: nil}
    app = to_string(artifact.app)

    {:reply, {:ok, activation},
     %{
       state
       | sequence: sequence,
         running: Map.put(state.running, app, activation),
         job: Map.put(state.job, :app, app)
     }}
  end

  defp worker_call({:bind, _}, state), do: {:reply, {:error, :plugins_blocked}, state}

  defp worker_call({:checkpoint, _, _}, %{blocked: blocked} = state) when not is_nil(blocked),
    do: {:reply, {:error, :plugins_blocked}, state}

  defp worker_call({:checkpoint, app, activation}, state) do
    case storage_check(state.job) do
      :ok -> {:reply, :ok, %{state | running: Map.put(state.running, app, activation)}}
      error -> {:reply, error, state}
    end
  end

  defp worker_call({:quiesce, app}, state) do
    if activation = state.running[app], do: Owner.quiesce(activation.owner)
    {:reply, :ok, %{state | job: Map.put(state.job, :app, app)}}
  end

  defp worker_call({:unloaded, app}, state) do
    if activation = state.running[app], do: Owner.revoke(activation.owner)
    {:reply, :ok, %{state | running: Map.delete(state.running, app)}}
  end

  defp worker_call({:persist, entries}, %{blocked: nil} = state) do
    result = with :ok <- storage_check(state.job), do: Metadata.persist(state.file, entries)

    case result do
      :ok ->
        {:reply, :ok, %{state | entries: entries}}

      {:error, :metadata_commit_unknown} = error ->
        {:reply, error, block(state, :metadata_commit_unknown)}

      error ->
        {:reply, error, state}
    end
  end

  defp worker_call({:persist, entries}, %{job: %{request: {:stop, _}}} = state) do
    case Metadata.persist(state.file, entries) do
      :ok -> {:reply, :ok, %{state | entries: entries}}
      error -> {:reply, error, state}
    end
  end

  defp worker_call({:persist, _}, state), do: {:reply, {:error, :plugins_blocked}, state}

  defp begin_work(request, from, state) do
    parent = self()
    op = make_ref()
    context = fn message -> GenServer.call(parent, {:worker, op, message}, 10_000) end

    task =
      Task.Supervisor.async(NervesGate.PluginTasks, fn ->
        try do
          run(request, state, context)
        catch
          _, _ -> {{:error, :lifecycle_failed}, %{state | blocked: :lifecycle_failed}}
        end
      end)

    timer = Process.send_after(self(), {:deadline, op}, @budget)

    %{
      state
      | job: %{
          op: op,
          task: task,
          timer: timer,
          from: from,
          app: nil,
          request: request,
          storage_identity: nil
        }
    }
  end

  @impl true
  def handle_info({ref, {reply, next}}, %{job: %{task: %{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(job.timer)
    if job.from, do: GenServer.reply(job.from, reply)
    # A timed-out worker may finish cleanup, but cannot undo the blocked outcome.
    cond do
      next.blocked ->
        {:noreply, %{block(state, next.blocked) | job: nil}}

      state.blocked && not (match?({:stop, _}, job.request) and reply == :ok) ->
        {:noreply, %{state | job: nil}}

      true ->
        {:noreply,
         %{
           state
           | entries: next.entries,
             running: next.running,
             errors: next.errors,
             blocked: nil,
             blocked_app: nil,
             job: nil,
             available?: next.available?,
             restored?: next.restored?
         }}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{task: %{ref: ref}} = job} = state) do
    Process.cancel_timer(job.timer)
    if job.from, do: GenServer.reply(job.from, {:error, :lifecycle_failed})
    {:noreply, block(state, :lifecycle_failed) |> Map.put(:job, nil)}
  end

  def handle_info({:deadline, op}, %{job: %{op: op} = job} = state) do
    if job.from, do: GenServer.reply(job.from, {:error, :operation_timeout})
    {:noreply, block(%{state | job: %{job | from: nil}}, :operation_timeout)}
  end

  def handle_info(:storage, %{blocked: blocked} = state) when not is_nil(blocked) do
    Process.send_after(self(), :storage, 1_000)
    {:noreply, state}
  end

  def handle_info(:storage, state) do
    Process.send_after(self(), :storage, 1_000)
    available? = true

    next = storage_changed(state, available?)
    {:noreply, %{next | available?: available?}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp storage_changed(%{job: job} = state, _) when not is_nil(job), do: state

  defp storage_changed(state, true) do
    ready? =
      Enum.all?(
        [NervesGate.Network, NervesGate.Hardware, NervesGate.SDKBackend],
        &Process.whereis/1
      )

    identity = Storage.identity()

    development_running? =
      Enum.any?(state.running, fn {_, activation} -> activation.artifact.source != :firmware end)

    changed? = identity != state.storage_identity

    cond do
      ready? and not state.restored? ->
        %{begin_work(:restore, nil, state) | storage_identity: identity}

      development_running? and changed? ->
        %{begin_work(:halt_development, nil, state) | storage_identity: nil}

      state.restored? and changed? and match?({:ok, _}, identity) ->
        %{begin_work(:restore_development, nil, state) | storage_identity: identity}

      true ->
        check_running(%{state | storage_identity: identity})
    end
  end

  defp check_running(state) do
    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    case Enum.find(state.running, fn {_, activation} ->
           activation.phase == :running and not MapSet.member?(started, activation.artifact.app)
         end) do
      nil -> state
      {app, _} -> begin_work({:unexpected_stop, app}, nil, state)
    end
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.running, fn {_, activation} -> Owner.quiesce(activation.owner) end)
    :ok
  end

  defp block(state, reason) do
    if state.job.app && state.running[state.job.app],
      do: Owner.quiesce(state.running[state.job.app].owner)

    %{state | blocked: reason, blocked_app: state.job.app || state.blocked_app}
  end

  defp storage_check(%{request: {:stop, _}}), do: :ok
  defp storage_check(%{storage_identity: :firmware}), do: :ok

  defp storage_check(%{storage_identity: identity}) do
    if Storage.identity() == {:ok, identity}, do: :ok, else: {:error, :storage_changed}
  end

  defp run({:stop, _} = request, state, context), do: perform(request, state, context)
  defp run(:halt_all, state, context), do: perform(:halt_all, state, context)
  defp run(:halt_development, state, context), do: perform(:halt_development, state, context)

  defp run(request, state, context) do
    identity =
      if firmware_request?(request, state), do: {:ok, :firmware}, else: Storage.identity()

    case identity do
      {:ok, identity} ->
        :ok = context.({:storage_identity, identity})
        perform(request, %{state | storage_identity: identity}, context)

      error ->
        {error, state}
    end
  end

  defp firmware_request?(operation, _) when operation in [:restore, :restore_development],
    do: true

  defp firmware_request?({:select, _, _}, _), do: true
  defp firmware_request?({:assign_port, _, _, _, _, _}, _), do: true

  defp firmware_request?({operation, app}, state)
       when operation in [:start, :stop, :restart, :rollback, :uninstall, :unexpected_stop],
       do: firmware_entry?(state.entries[to_string(app)])

  defp firmware_request?(_, _), do: false

  defp firmware_entry?(%{active_version: version, artifacts: artifacts}),
    do: artifacts[version].source == :firmware

  defp firmware_entry?(_), do: false

  defp missing_selection(app, entry) do
    if firmware_entry?(entry) and not Bundled.selected?(app, entry), do: :plugin_not_in_firmware
  end

  defp capabilities(state) do
    Map.new(state.entries, fn {app, entry} ->
      kinds =
        case Artifact.load(app, entry.active_version, entry.artifacts[entry.active_version]) do
          {:ok, _, package} -> package.main.env[:nerves_gate_hardware] || []
          _ -> []
        end

      {app, kinds}
    end)
  end

  defp assignment_unchanged(_, nil), do: :ok
  defp assignment_unchanged(setting, setting), do: :ok
  defp assignment_unchanged(_, _), do: {:error, :assignment_changed}

  defp reserve_assignment(port, needed) when port in ["eth0", "eth1"],
    do: NervesGate.Network.reserve_hardware(port, needed)

  defp reserve_assignment(_, _), do: :ok

  defp stop_and_assign(affected, port, setting, state, context) do
    affected = Enum.filter(affected, &Map.has_key?(state.entries, &1))

    result =
      Enum.reduce_while(affected, {:ok, state}, fn app, {:ok, next} ->
        case lifecycle(:stop, app, next, context) do
          {:ok, stopped} -> {:cont, {:ok, stopped}}
          {error, stopped} -> {:halt, {error, stopped}}
        end
      end)

    case result do
      {:ok, next} ->
        ports = Map.put(next.assignments, port, setting)

        case context.({:assignments, ports}) do
          :ok -> {:ok, %{next | assignments: ports}}
          error -> {error, next}
        end

      failure ->
        failure
    end
  end

  defp perform({:assign_port, port, enabled, plugin, confirmed, expected}, state, context) do
    old = state.assignments[port] || %{enabled: false, plugin: nil}
    affected = Enum.reject(Enum.uniq([old.plugin, plugin]), &is_nil/1)
    running = Enum.filter(affected, &Map.has_key?(state.running, &1))

    with nil <- state.assignment_error,
         :ok <- assignment_unchanged(old, expected),
         :ok <-
           Assignments.validate(
             port,
             enabled,
             plugin,
             NervesGate.Hardware.inventory(),
             capabilities(state)
           ),
         true <- running == [] or confirmed == true,
         :ok <- reserve_assignment(port, enabled or plugin != nil) do
      stop_and_assign(affected, port, %{enabled: enabled, plugin: plugin}, state, context)
    else
      false -> {{:error, :stop_confirmation_required}, state}
      {:error, _} = error -> {error, state}
      _ -> {{:error, :hardware_assignments_unavailable}, state}
    end
  end

  defp perform({:select, name, version}, state, context) do
    app = to_string(name)

    with true <- firmware_entry?(state.entries[app]) and Bundled.version(app) == version,
         {:ok, next} <- halt(app, state, context),
         {:ok, next} <-
           save(
             next,
             app,
             %{
               next.entries[app]
               | active_version: version,
                 previous_version: nil,
                 enabled: false
             },
             context
           ) do
      {:ok, %{next | errors: Map.delete(next.errors, app)}}
    else
      false -> {{:error, :plugin_not_in_firmware}, state}
      {:error, reason, next} -> {{:error, reason}, next}
    end
  end

  defp perform({:install_new, path, expected}, state, context) do
    with {:ok, package, bytes, sha} <- Artifact.read(path),
         :ok <- Artifact.review(package, sha, expected, state.entries),
         %{ready: true, card_id: card} when card == expected.card_id <- Storage.commissioning() do
      case context.(:check_storage) do
        :ok -> install(package, bytes, sha, state, context)
        error -> {error, state}
      end
    else
      _ -> {{:error, :review_changed}, state}
    end
  end

  defp perform({operation, path}, state, context) when operation in [:install, :upgrade] do
    with {:ok, _} <- Storage.plugins_dir(),
         {:ok, package, bytes, sha} <- Artifact.read(path),
         :ok <- context.(:check_storage) do
      install_request(operation, package, bytes, sha, state, context)
    else
      error -> {error, state}
    end
  end

  defp perform({operation, name}, state, context)
       when operation in [:start, :stop, :restart, :rollback, :uninstall] do
    app = to_string(name)

    if Package.valid_name?(app) and Map.has_key?(state.entries, app),
      do: lifecycle(operation, app, state, context),
      else: {{:error, :not_installed}, state}
  end

  defp perform({:unexpected_stop, app}, state, context) do
    case halt(app, state, context) do
      {:ok, next} ->
        {{:error, :plugin_stopped}, %{next | errors: Map.put(next.errors, app, :plugin_stopped)}}

      {:error, reason, next} ->
        {{:error, reason}, next}
    end
  end

  defp perform(operation, state, context) when operation in [:halt_all, :halt_development] do
    apps =
      Enum.reject(
        Map.keys(state.running),
        &(operation == :halt_development and firmware_entry?(state.entries[&1]))
      )

    Enum.reduce_while(apps, {:ok, state}, fn app, {_, state} ->
      case halt(app, state, context) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason, next} -> {:halt, {{:error, reason}, %{next | blocked: reason}}}
      end
    end)
  end

  defp perform(:restore_development, state, context) do
    entries = Map.reject(state.entries, fn {_, entry} -> firmware_entry?(entry) end)

    with :ok <- Loader.drain(:inactive), :ok <- reconcile(entries) do
      {:ok, Enum.reduce_while(entries, state, &restore_entry(&1, &2, context))}
    else
      {:error, reason} -> {{:error, reason}, %{state | blocked: reason}}
    end
  end

  defp perform(:restore, state, context) do
    with :ok <- UI.close_all(),
         :ok <- Loader.drain(:inactive),
         :ok <- reconcile(state.entries) do
      next = Enum.reduce_while(state.entries, state, &restore_entry(&1, &2, context))

      {:ok, %{next | restored?: true, available?: true}}
    else
      {:error, reason} -> {{:error, reason}, %{state | blocked: reason, restored?: true}}
    end
  end

  defp perform(_, state, _), do: {{:error, :invalid_request}, state}

  defp install_request(:upgrade, package, bytes, sha, state, context) do
    app = to_string(package.app)

    if Map.has_key?(state.entries, app) do
      upgrade_installed(
        install(package, bytes, sha, state, context),
        app,
        package.version,
        context
      )
    else
      {{:error, :not_installed}, state}
    end
  end

  defp install_request(:install, package, bytes, sha, state, context),
    do: install(package, bytes, sha, state, context)

  defp upgrade_installed({{:ok, _}, state}, app, version, context),
    do: switch(app, version, state, context)

  defp upgrade_installed(result, _, _, _), do: result

  defp restore_entry(_, %{assignment_error: error} = state, _) when not is_nil(error),
    do: {:cont, state}

  defp restore_entry({app, %{enabled: true} = entry}, state, context) do
    identity = if firmware_entry?(entry), do: {:ok, :firmware}, else: Storage.identity()

    case identity do
      {:ok, identity} ->
        :ok = context.({:storage_identity, identity})
        restore_selected(app, state, context)

      {:error, reason} ->
        {:cont, %{state | errors: Map.put(state.errors, app, reason)}}
    end
  end

  defp restore_entry(_, state, _), do: {:cont, state}

  defp restore_selected(app, state, context) do
    case start_selected(app, state, context) do
      {:ok, next} ->
        {:cont, next}

      {{:error, reason}, next} ->
        next = %{next | errors: Map.put(next.errors, app, reason)}
        if next.blocked, do: {:halt, next}, else: {:cont, next}
    end
  end

  defp install(package, bytes, sha, state, context) do
    app = to_string(package.app)
    previous = state.running[app] && state.running[app].artifact
    registered = get_in(state.entries, [app, :artifacts, package.version])

    cond do
      Bundled.member?(app) or firmware_entry?(state.entries[app]) ->
        {{:error, :firmware_owned_plugin}, state}

      registered && registered.sha256 != sha ->
        {{:error, :artifact_conflict}, state}

      registered ->
        {{:ok, %{app: package.app, version: package.version, sha256: sha}}, state}

      true ->
        with :ok <- Artifact.validate(package, state.entries, app, previous),
             {:ok, artifact} <- Artifact.install(package, bytes, sha),
             entry =
               Map.get(state.entries, app, %{
                 enabled: false,
                 active_version: package.version,
                 previous_version: nil,
                 generation: 0,
                 artifacts: %{}
               }),
             entry = %{
               entry
               | artifacts:
                   Map.put(entry.artifacts, package.version, Artifact.descriptor(artifact))
             },
             {:ok, next} <- save(state, app, entry, context) do
          {{:ok, %{app: package.app, version: package.version, sha256: sha}}, next}
        else
          {:error, reason, next} -> {{:error, reason}, next}
          {:error, reason} -> {{:error, reason}, state}
        end
    end
  end

  defp lifecycle(:start, _app, %{assignment_error: error} = state, _context)
       when not is_nil(error),
       do: {{:error, :hardware_assignments_unavailable}, state}

  defp lifecycle(:start, app, state, context) do
    case state.running[app] do
      %{phase: :running} ->
        {:ok, state}

      nil ->
        start_selected(app, state, context)

      _ ->
        {{:error, :cleanup_pending}, state}
    end
  end

  defp lifecycle(:stop, app, state, context) do
    with {:ok, next} <- save(state, app, %{state.entries[app] | enabled: false}, context),
         {:ok, next} <- halt(app, next, context) do
      {:ok, %{next | blocked: nil}}
    else
      {:error, reason, next} -> {{:error, reason}, next}
    end
  end

  defp lifecycle(:restart, app, state, context) do
    case halt(app, state, context) do
      {:ok, next} -> lifecycle(:start, app, next, context)
      {:error, reason, next} -> {{:error, reason}, next}
    end
  end

  defp lifecycle(:rollback, app, state, context) do
    case state.entries[app].previous_version do
      nil -> {{:error, :no_previous_version}, state}
      version -> switch(app, version, state, context)
    end
  end

  defp lifecycle(:uninstall, app, state, context) do
    if firmware_entry?(state.entries[app]) do
      {{:error, :firmware_owned_plugin}, state}
    else
      uninstall_development(app, state, context)
    end
  end

  defp uninstall_development(app, state, context) do
    case lifecycle(:stop, app, state, context) do
      {:ok, next} ->
        with {:ok, root} <- Storage.plugins_dir(),
             :ok <- remove_artifacts(root, app, next.entries[app]),
             :ok <- context.({:persist, Map.delete(next.entries, app)}) do
          {:ok,
           %{next | entries: Map.delete(next.entries, app), errors: Map.delete(next.errors, app)}}
        else
          {:error, reason} -> {{:error, reason}, next}
        end

      result ->
        result
    end
  end

  defp start_selected(app, state, context) do
    result =
      with {:ok, next} <- launch(app, state.entries[app].active_version, state, context),
           do: commit_running(app, next, context)

    case result do
      {:ok, next} ->
        {:ok, next}

      {:error, reason, next} ->
        {{:error, reason}, %{next | errors: Map.put(next.errors, app, reason)}}
    end
  end

  defp switch(app, version, state, context) do
    old = state.entries[app]
    previous = state.running[app] && state.running[app].artifact

    with false <- version == old.active_version,
         {:ok, artifact, package} <- Loader.prepare(app, version, state.entries, previous),
         {:ok, stopped} <- halt(app, state, context) do
      selected =
        put_in(stopped.entries[app], %{
          old
          | active_version: version,
            previous_version: old.active_version,
            enabled: true
        })

      result =
        with {:ok, started} <- activate(artifact, package, selected, context),
             do: commit_running(app, started, context)

      case result do
        {:ok, next} ->
          {:ok, next}

        {:error, reason, next} ->
          rollback_failed(app, old, previous != nil, reason, next, context)
      end
    else
      true -> {{:error, :already_active}, state}
      {:error, reason, next} -> {{:error, reason}, next}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp rollback_failed(app, old, was_running, reason, state, context) do
    with {:ok, stopped} <- halt(app, state, context),
         stopped = put_in(stopped.entries[app], old),
         {:ok, restored} <- restore_previous(app, was_running, stopped, context) do
      error = {:rolled_back, reason}
      {{:error, error}, %{restored | errors: Map.put(restored.errors, app, error)}}
    else
      {:error, cleanup, next} ->
        {{:error, {:rollback_failed, reason, cleanup}}, %{next | blocked: :rollback_failed}}
    end
  end

  defp restore_previous(app, true, state, context) do
    with {:ok, started} <- launch(app, state.entries[app].active_version, state, context),
         do: commit_running(app, started, context)
  end

  defp restore_previous(_, false, state, _), do: {:ok, state}

  defp launch(app, version, state, context) do
    case Loader.prepare(app, version, state.entries, nil) do
      {:ok, artifact, package} -> activate(artifact, package, state, context)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp activate(artifact, package, state, context) do
    app = to_string(artifact.app)

    case context.({:bind, artifact}) do
      {:ok, activation} -> activate_bound(app, activation, package, state, context)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp activate_bound(app, activation, package, state, context) do
    state = put_in(state.running[app], activation)

    case Loader.activate(activation, package, &context.({:checkpoint, app, &1})) do
      {:ok, activation} ->
        {:ok, put_in(state.running[app], activation)}

      {:error, reason, partial} ->
        activation_failed(app, reason, put_in(state.running[app], partial), context)
    end
  end

  defp activation_failed(app, reason, state, context) do
    case halt(app, state, context) do
      {:ok, stopped} -> {:error, reason, stopped}
      {:error, cleanup, next} -> {:error, {:cleanup_failed, reason, cleanup}, next}
    end
  end

  defp commit_running(app, state, context) do
    activation = state.running[app]
    {_, sequence} = activation.owner.generation

    case save(state, app, %{state.entries[app] | enabled: true, generation: sequence}, context) do
      {:ok, next} -> {:ok, %{next | errors: Map.delete(next.errors, app)}}
      {:error, reason, next} -> activation_failed(app, reason, next, context)
    end
  end

  defp halt(app, state, context) do
    case state.running[app] do
      nil ->
        {:ok, state}

      activation ->
        ports = Enum.filter(:erlang.ports(), &owned_port?(&1, activation.owner))

        :ok = context.({:quiesce, app})

        result = with :ok <- Loader.unload(activation), do: ports_closed(ports)

        case result do
          :ok ->
            :ok = context.({:unloaded, app})
            {:ok, %{state | running: Map.delete(state.running, app)}}

          {:error, reason} ->
            {:error, reason, %{state | blocked: :cleanup_pending}}
        end
    end
  end

  defp owned_port?(port, owner) do
    case :erlang.port_info(port, :connected) do
      {:connected, pid} -> Owner.matches?(pid, owner, :release)
      _ -> false
    end
  end

  defp ports_closed(ports) do
    if Enum.all?(ports, &(:erlang.port_info(&1) == :undefined)),
      do: :ok,
      else: {:error, :hardware_cleanup_pending}
  end

  defp save(state, app, entry, context) do
    entries = Map.put(state.entries, app, entry)

    case context.({:persist, entries}) do
      :ok -> {:ok, %{state | entries: entries}}
      {:error, reason} -> {:error, {:metadata_write, reason}, state}
    end
  end

  defp reconcile(entries) do
    Enum.reduce_while(entries, :ok, fn {app, entry}, :ok ->
      if firmware_entry?(entry) or match?({:ok, _}, Storage.root()),
        do: continue(reconcile_plugin(app, entry)),
        else: {:cont, :ok}
    end)
  end

  defp reconcile_plugin(app, entry) do
    Enum.reduce_while(entry.artifacts, :ok, fn {version, metadata}, :ok ->
      continue(reconcile_artifact(app, version, metadata))
    end)
  end

  defp reconcile_artifact(app, version, metadata) do
    case Artifact.load(app, version, metadata) do
      {:ok, artifact, _} ->
        if Loader.present?(artifact),
          do: Loader.unload(%{artifact: artifact, owner: nil, started: [], phase: :quiescing}),
          else: :ok

      {:error, :plugin_not_in_firmware} ->
        :ok

      error ->
        error
    end
  end

  defp remove_artifacts(root, app, entry) do
    Enum.reduce_while(entry.artifacts, :ok, fn {version, metadata}, :ok ->
      continue(remove_artifact(root, app, version, metadata))
    end)
  end

  defp remove_artifact(root, app, version, metadata) do
    with {:ok, _, _} <- Artifact.load(app, version, metadata) do
      path = Path.join([root, app, version])
      Artifact.remove_stage(path)
      if File.exists?(path), do: {:error, :artifact_removal_failed}, else: :ok
    end
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}
end

defmodule NervesGate.Apps do
  @moduledoc "Serialized cold lifecycle for immutable SD artifacts and generation-fenced, trusted OTP applications. Not a sandbox."
  use GenServer
  alias NervesGate.Apps.{Artifact, Loader, Metadata, Owner, Releases, UI}
  alias NervesGate.Storage
  alias NervesGateSDK.Package
  @timeout 190_000
  @budget 180_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def install(path), do: command({:install, path})
  def install_new(path, expected), do: command({:install_new, path, expected})
  def list, do: GenServer.call(__MODULE__, :list)
  def available_releases, do: Releases.available()
  def review_release(app, version), do: command({:review_release, app, version})
  def install_release(token), do: command({:install_release, token})
  @doc false
  def mount_ui(app), do: GenServer.call(__MODULE__, {:mount_ui, app})
  def start(app), do: command({:start, app})
  def stop(app), do: command({:stop, app})
  def restart(app), do: command({:restart, app})
  def upgrade(path), do: command({:upgrade, path})
  def rollback(app), do: command({:rollback, app})
  def uninstall(app), do: command({:uninstall, app})
  defp command(request), do: GenServer.call(__MODULE__, request, @timeout)

  @doc "Read-only current device prerequisites for a reviewed new-app install."
  def install_review(%{"app" => app, "platform" => platform}) do
    storage = Storage.commissioning()
    {:ok, apps} = list()
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
      installed: Enum.any?(apps, &(&1.app == app)),
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
         Regex.match?(~r|\A/tmp/nerves-gate-app-[a-f0-9]{32}/application\.ez\z|, path) do
      File.rm(path)
      File.rmdir(Path.dirname(path))
    end
  end

  defp reviewed_outcome({:ok, _}, expected) do
    {:ok, apps} = list()

    if Enum.any?(
         apps,
         &(&1.app == expected.app and &1.active_version == expected.version and
             &1.sha256 == expected.sha256 and not &1.enabled and not &1.running?)
       ), do: "installed_stopped", else: "unknown"
  end

  defp reviewed_outcome({:error, _}, _), do: "rejected"
  defp reviewed_outcome(_, _), do: "unknown"

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    Owner.init()
    file = Application.get_env(:nerves_gate, :apps_metadata, "/data/nerves_gate/apps.term")

    {entries, blocked} =
      case Metadata.read(file) do
        {:ok, entries} -> {entries, nil}
        {:error, reason} -> {%{}, reason}
      end

    state = %{
      file: file,
      entries: entries,
      running: %{},
      errors: %{},
      job: nil,
      release_review: nil,
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

  @impl true
  def handle_call(:list, _, %{blocked: :invalid_app_metadata} = state),
    do: {:reply, {:error, :invalid_app_metadata}, state}

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
          error: state.errors[app] || state.blocked
        }
      end

    {:reply, {:ok, Enum.sort_by(entries, & &1.app)}, state}
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
    if state.blocked != nil or state.job != nil or map_size(state.entries) != 0 or
         map_size(state.running) != 0 do
      {:reply,
       {:error,
        %{
          code: "applications_installed",
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
        {:reply, {:error, :applications_blocked}, state}

      not (state.restored? and state.available?) and not match?({:stop, _}, request) ->
        {:reply, {:error, :applications_not_ready}, state}

      true ->
        admit(request, from, state)
    end
  end

  defp admit({:install_release, token}, from, state) do
    case state.release_review do
      %{token: ^token, expires: expires, review: review} when is_reference(token) ->
        state = %{state | release_review: nil}

        if System.monotonic_time(:millisecond) < expires,
          do: {:noreply, begin_work({:install_release, review}, from, state)},
          else: {:reply, {:error, :release_review_expired}, state}

      _ ->
        {:reply, {:error, :release_review_expired}, state}
    end
  end

  defp admit(request, from, state), do: {:noreply, begin_work(request, from, state)}

  defp recovery?({:stop, app}, blocked) when is_binary(app) or is_atom(app),
    do: to_string(app) == blocked

  defp recovery?(_, _), do: false

  defp worker_call({:release_review, review}, %{blocked: nil} = state) do
    token = make_ref()

    stored = %{
      token: token,
      expires: System.monotonic_time(:millisecond) + 600_000,
      review: review
    }

    {:reply,
     {:ok,
      %{token: token, release: review.release, action: review.action, selection: review.selection}},
     %{state | release_review: stored}}
  end

  defp worker_call({:release_review, _}, state),
    do: {:reply, {:error, :applications_blocked}, state}

  defp worker_call(:check_storage, %{blocked: nil} = state),
    do: {:reply, storage_check(state.job), state}

  defp worker_call(:check_storage, state), do: {:reply, {:error, :applications_blocked}, state}

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

  defp worker_call({:bind, _}, state), do: {:reply, {:error, :applications_blocked}, state}

  defp worker_call({:checkpoint, _, _}, %{blocked: blocked} = state) when not is_nil(blocked),
    do: {:reply, {:error, :applications_blocked}, state}

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

  defp worker_call({:persist, _}, state), do: {:reply, {:error, :applications_blocked}, state}

  defp begin_work(request, from, state) do
    parent = self()
    op = make_ref()
    context = fn message -> GenServer.call(parent, {:worker, op, message}, 10_000) end

    task =
      Task.Supervisor.async(NervesGate.AppTasks, fn ->
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
    available? = match?({:ok, _}, Storage.root())

    next = storage_changed(state, available?)
    {:noreply, %{next | available?: available?}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp storage_changed(%{job: job} = state, _) when not is_nil(job), do: state

  defp storage_changed(state, true) do
    ready? =
      Enum.all?([NervesGate.Network, NervesGate.Buses, NervesGate.SDKBackend], &Process.whereis/1)

    if ready? and (not state.restored? or not state.available?),
      do: begin_work(:restore, nil, state),
      else: check_running(state)
  end

  defp storage_changed(state, false) do
    if map_size(state.running) > 0, do: begin_work(:halt_all, nil, state), else: state
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

  defp storage_check(%{storage_identity: identity}) do
    if Storage.identity() == {:ok, identity}, do: :ok, else: {:error, :storage_changed}
  end

  defp run({:stop, _} = request, state, context), do: perform(request, state, context)
  defp run(:halt_all, state, context), do: perform(:halt_all, state, context)

  defp run(request, state, context) do
    case Storage.identity() do
      {:ok, identity} ->
        :ok = context.({:storage_identity, identity})
        perform(request, %{state | storage_identity: identity}, context)

      error ->
        {error, state}
    end
  end

  defp perform({:review_release, app, version}, state, context) do
    with {:ok, release} <- Releases.review(app, version),
         :ok <- release_version(app, version, state.entries) do
      review = %{
        release: release,
        action: if(state.entries[app], do: :upgrade, else: :install),
        selection: release_selection(app, state),
        storage_identity: state.storage_identity
      }

      {context.({:release_review, review}), state}
    else
      error -> {error, state}
    end
  end

  defp perform({:install_release, review}, state, context) do
    app = review.release["app"]

    with true <-
           review.storage_identity == state.storage_identity and
             review.selection == release_selection(app, state),
         {:ok, package, bytes, sha} <- Releases.download(review.release),
         :ok <- context.(:check_storage) do
      install_request(review.action, package, bytes, sha, state, context)
    else
      false -> {{:error, :release_review_changed}, state}
      error -> {error, state}
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
    with {:ok, _} <- Storage.apps_dir(),
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
        {{:error, :application_stopped},
         %{next | errors: Map.put(next.errors, app, :application_stopped)}}

      {:error, reason, next} ->
        {{:error, reason}, next}
    end
  end

  defp perform(:halt_all, state, context) do
    Enum.reduce_while(Map.keys(state.running), {:ok, state}, fn app, {_, state} ->
      case halt(app, state, context) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason, next} -> {:halt, {{:error, reason}, %{next | blocked: reason}}}
      end
    end)
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

  defp release_version(app, version, entries) do
    case entries[app] do
      nil ->
        :ok

      %{active_version: ^version} ->
        {:error, :already_active}

      %{active_version: active} ->
        if Version.compare(version, active) == :gt,
          do: :ok,
          else: {:error, :release_downgrade_unsupported}
    end
  end

  defp release_selection(app, state) do
    case state.entries[app] do
      nil ->
        nil

      entry ->
        Map.take(entry, [:active_version, :enabled, :generation])
        |> Map.put(:running?, match?(%{phase: :running}, state.running[app]))
    end
  end

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

  defp restore_entry({app, %{enabled: true}}, state, context) do
    case start_selected(app, state, context) do
      {:ok, next} ->
        {:cont, next}

      {{:error, reason}, next} ->
        next = %{next | errors: Map.put(next.errors, app, reason)}
        if next.blocked, do: {:halt, next}, else: {:cont, next}
    end
  end

  defp restore_entry(_, state, _), do: {:cont, state}

  defp install(package, bytes, sha, state, context) do
    app = to_string(package.app)
    previous = state.running[app] && state.running[app].artifact
    registered = get_in(state.entries, [app, :artifacts, package.version])

    cond do
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
    case lifecycle(:stop, app, state, context) do
      {:ok, next} ->
        with {:ok, root} <- Storage.apps_dir(),
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

    with {:ok, _} <- Storage.apps_dir(),
         {:ok, next} <-
           save(state, app, %{state.entries[app] | enabled: true, generation: sequence}, context) do
      {:ok, %{next | errors: Map.delete(next.errors, app)}}
    else
      {:error, reason, next} -> activation_failed(app, reason, next, context)
      {:error, reason} -> activation_failed(app, reason, state, context)
    end
  end

  defp halt(app, state, context) do
    case state.running[app] do
      nil ->
        {:ok, state}

      activation ->
        :ok = context.({:quiesce, app})

        case Loader.unload(activation) do
          :ok ->
            :ok = context.({:unloaded, app})
            {:ok, %{state | running: Map.delete(state.running, app)}}

          {:error, reason} ->
            {:error, reason, %{state | blocked: :cleanup_pending}}
        end
    end
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
      continue(reconcile_app(app, entry))
    end)
  end

  defp reconcile_app(app, entry) do
    Enum.reduce_while(entry.artifacts, :ok, fn {version, metadata}, :ok ->
      continue(reconcile_artifact(app, version, metadata))
    end)
  end

  defp reconcile_artifact(app, version, metadata) do
    with {:ok, artifact, _} <- Artifact.load(app, version, metadata) do
      if Loader.present?(artifact),
        do: Loader.unload(%{artifact: artifact, owner: nil, started: [], phase: :quiescing}),
        else: :ok
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

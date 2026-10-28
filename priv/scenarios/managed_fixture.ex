defmodule ManagedFixture.Application do
  use Application

  def start(_, _) do
    if Application.get_env(:managed_fixture, :fixture_start) == :fail do
      {:error, :fixture_start_failed}
    else
      Supervisor.start_link(
        [
          {DynamicSupervisor, strategy: :one_for_one, name: ManagedFixture.Clients},
          {ManagedFixture.Client, name: ManagedFixture.Main}
        ],
        strategy: :one_for_one
      )
    end
  end

  def stop(_) do
    directory =
      Application.get_env(:nerves_gate, :plugins_metadata, "/data/nerves_gate/plugins.term")
      |> Path.dirname()

    held = directory <> ".held"

    if String.starts_with?(directory, "/tmp/lifecycle-metadata-") and File.regular?(directory) and
         File.dir?(held) do
      File.rm!(directory)
      File.rename!(held, directory)
    end

    :ok
  end

  def health_check do
    case Application.get_env(:managed_fixture, :fixture_health, :ok) do
      :fail ->
        {:error, :not_ready}

      :timeout ->
        Process.sleep(6_000)
        :ok

      :hold ->
        Process.register(self(), ManagedFixture.Health)

        receive do
          :continue -> :ok
        end

      :corrupt_previous ->
        # These administrative fault hooks exist only on the real guest firmware,
        # never in this independently compiled SDK fixture project's dependencies.
        {:ok, entries} = apply(NervesGate.Plugins, :list, [])
        selected = Enum.find(entries, &(&1.app == "managed_fixture"))
        {:ok, root} = apply(NervesGate.Storage, :plugins_dir, [])
        archive = Path.join([root, "managed_fixture", selected.active_version, "package.ez"])
        File.write!(archive, "deliberately corrupted disposable rollback archive")
        {:error, :fixture_corruption}

      :commit_failure ->
        directory = Application.fetch_env!(:nerves_gate, :plugins_metadata) |> Path.dirname()
        true = String.starts_with?(directory, "/tmp/lifecycle-metadata-")
        File.rename!(directory, directory <> ".held")
        File.write!(directory, "metadata commit denied by disposable fixture")
        :ok

      :ok ->
        :ok
    end
  end
end

defmodule ManagedFixture.Client do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

  def init(_) do
    # This is a real managed application PID, including during startup callbacks.
    :ok = NervesGateSDK.Events.subscribe(:system)
    {:ok, []}
  end

  def handle_call({:invoke, module, function, args}, _, events),
    do: {:reply, apply(module, function, args), events}

  def handle_call(:events, _, events), do: {:reply, Enum.reverse(events), []}

  def handle_info(:app_ui_close, events), do: {:stop, :normal, events}

  def handle_info(%NervesGateSDK.Events.Event{} = event, events),
    do: {:noreply, Enum.take([event | events], 32)}
end

defmodule ManagedFixture.Hold do
  def wait do
    receive do
      :release -> :ok
    end
  end
end

defmodule ManagedFixture.Preload do
  @on_load :load
  def load do
    if Application.get_env(:managed_fixture, :fixture_preload) == :fail,
      do: {:error, :fixture_preload_failed},
      else: :ok
  end
end

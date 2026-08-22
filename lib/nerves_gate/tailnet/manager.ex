defmodule NervesGate.Tailnet.Manager do
  @moduledoc "Owns the local tailscaled runtime and repairs it only when Internet is available."

  use GenServer

  alias NervesGate.Backoff
  alias NervesGate.Store

  @initial_retry 1_000
  @maximum_retry 60_000

  defstruct [
    :child,
    :monitor,
    :binary_paths,
    retry: @initial_retry,
    enabled: true,
    internet_online: false
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec ensure_started(GenServer.server()) :: :ok | {:error, term()}
  def ensure_started(server \\ __MODULE__), do: GenServer.call(server, :ensure_started, 15_000)

  @spec repair_runtime(GenServer.server()) :: :ok | :blocked
  def repair_runtime(server \\ __MODULE__), do: GenServer.call(server, :repair_runtime)

  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.call(server, :running?)

  @spec validate_binary_paths(map()) :: :ok | {:error, :missing_pinned_binary}
  def validate_binary_paths(paths) do
    if executables?(paths), do: :ok, else: {:error, :missing_pinned_binary}
  end

  @impl true
  def init(options) do
    enabled =
      Keyword.get(options, :enabled, Application.get_env(:nerves_gate, :tailscale_enabled, true))

    Phoenix.PubSub.subscribe(NervesGate.PubSub, "internet")

    {:ok,
     %__MODULE__{
       enabled: enabled,
       binary_paths: Keyword.get(options, :binary_paths),
       retry: Keyword.get(options, :retry, @initial_retry),
       internet_online: internet_online?()
     }}
  end

  @impl true
  def handle_call(:ensure_started, _from, %{enabled: false} = state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call(:ensure_started, _from, %{child: pid} = state) when is_pid(pid),
    do: {:reply, :ok, state}

  def handle_call(:ensure_started, _from, state) do
    case start_runtime(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:repair_runtime, _from, %{internet_online: false} = state) do
    {:reply, :blocked, state}
  end

  def handle_call(:repair_runtime, _from, %{child: pid} = state) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    {:reply, :ok, state}
  end

  def handle_call(:repair_runtime, _from, state) do
    send(self(), :restart)
    {:reply, :ok, state}
  end

  def handle_call(:running?, _from, state), do: {:reply, is_pid(state.child), state}

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{monitor: reference} = state) do
    state = %{state | child: nil, monitor: nil}

    if state.internet_online do
      {wait, next_retry} = Backoff.next(state.retry, @maximum_retry)
      Process.send_after(self(), :restart, wait)
      {:noreply, %{state | retry: next_retry}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:restart, %{child: nil, enabled: true, internet_online: true} = state) do
    case start_runtime(state) do
      {:ok, state} ->
        {:noreply, %{state | retry: @initial_retry}}

      {:error, _reason, state} ->
        {wait, next_retry} = Backoff.next(state.retry, @maximum_retry)
        Process.send_after(self(), :restart, wait)
        {:noreply, %{state | retry: next_retry}}
    end
  end

  def handle_info(:restart, state), do: {:noreply, state}

  def handle_info({:internet_changed, %{online: online}}, state) do
    state = %{state | internet_online: online}
    if online and is_nil(state.child), do: send(self(), :restart)
    {:noreply, state}
  end

  defp start_runtime(state) do
    with {:ok, paths} <- locate_binaries(state),
         {:ok, pid} <- start_tailscale(paths) do
      {:ok,
       %{
         state
         | child: pid,
           monitor: Process.monitor(pid),
           retry: @initial_retry
       }}
    else
      {:error, reason} -> {:error, classify(reason), state}
    end
  end

  defp locate_binaries(%{binary_paths: paths}) when is_map(paths) do
    if validate_binary_paths(paths) == :ok,
      do: {:ok, paths},
      else: {:error, :missing_pinned_binary}
  end

  defp locate_binaries(_state) do
    bundled = Application.fetch_env!(:nerves_gate, :tailscale_binaries)

    if verified_binary_paths?(bundled),
      do: {:ok, bundled},
      else: {:error, :missing_pinned_binary}
  end

  defp verified_binary_paths?(paths) do
    checksums = Application.fetch_env!(:nerves_gate, :tailscale_binary_sha256)

    validate_binary_paths(paths) == :ok and
      sha256(paths.cli_path) == checksums.cli and
      sha256(paths.daemon_path) == checksums.daemon
  end

  defp sha256(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp executables?(paths) do
    executable?(paths.cli_path) and executable?(paths.daemon_path)
  end

  defp executable?(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0,
         {:ok, <<0x7F, "ELF">>} <- read_elf_magic(path) do
      true
    else
      _other -> false
    end
  end

  defp read_elf_magic(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]),
         data <- IO.binread(file, 4),
         :ok <- File.close(file) do
      {:ok, data}
    end
  end

  defp start_tailscale(paths) do
    if Nerves.Runtime.mix_target() != :host and not File.exists?("/dev/net/tun") do
      {:error, :kernel_tun_unavailable}
    else
      with :ok <- configure_cache() do
        options = [
          name: NervesGate.Tailscale.Daemon,
          daemon_path: paths.daemon_path,
          cli_path: paths.cli_path,
          socket_path: Path.join(Store.root(), "tailscale/tailscaled.sock"),
          tailscale_dir: Path.join(Store.root(), "tailscale/state"),
          tun: :kernel,
          timeout: 8_000
        ]

        child_spec = %{
          id: NervesGate.Tailscale.Daemon,
          start: {Tailscale, :start_link, [options]},
          restart: :temporary
        }

        DynamicSupervisor.start_child(NervesGate.Tailnet.DynamicSupervisor, child_spec)
      end
    end
  end

  defp configure_cache do
    cache = Path.join(Store.root(), "tailscale/cache")

    with :ok <- File.mkdir_p(cache) do
      System.put_env("XDG_CACHE_HOME", cache)
    end
  end

  defp internet_online?, do: NervesGate.Internet.Monitor.status().online

  defp classify(reason)
       when reason in [:kernel_tun_unavailable, :missing_pinned_binary, :disabled],
       do: reason

  defp classify(_reason), do: :tailscale_start_failed
end

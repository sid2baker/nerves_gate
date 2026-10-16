defmodule NervesGate.Simulator do
  @moduledoc "Host-only lifecycle owner of disposable QEMU devices. No devices start with this server."
  use GenServer
  alias NervesGate.Simulator.{Device, Qemu}

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def subscribe(node), do: GenServer.call({__MODULE__, node}, {:subscribe, self()})
  def lifecycle(node, action), do: GenServer.call({__MODULE__, node}, {:lifecycle, action})
  def devices, do: GenServer.call(__MODULE__, :devices)
  def devices(node), do: GenServer.call({__MODULE__, node}, :devices)

  def command(%{owner: owner}, command, args \\ []) do
    # Never send cleanup or another command after a call with unknown outcome.
    if Process.get(:simulator_control_failed), do: exit(:simulator_control_failed)
    GenServer.call(owner, {:command, command, args}, 480_000)
  catch
    :exit, _ ->
      Process.put(:simulator_control_failed, true)
      exit(:simulator_control_failed)
  end

  def observe(device), do: command(device, :observe)
  def network(device, patch), do: command(device, :network, [patch])

  def config(path, dir) do
    {config, _} = Code.eval_file(path)
    true = is_map(config.devices) and map_size(config.devices) in 1..253
    firmware = Path.expand(config.firmware)
    factory = Path.expand(Map.get(config, :factory_firmware, firmware))
    Map.merge(config, %{dir: dir, firmware: firmware, factory_firmware: factory})
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    view = %{
      status: :stopped,
      phase: "Simulator empty. Start configured devices to build firmware and boot.",
      devices: config.devices |> Map.keys() |> Enum.sort(),
      progress: %{},
      reset_required: false
    }

    {:ok,
     %{
       config: config,
       view: view,
       devices: %{},
       supervisor: nil,
       worker: nil,
       token: nil,
       subscriber: nil,
       prepared: false
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _, state),
    do: {:reply, state.view, %{state | subscriber: pid}}

  def handle_call(:devices, _, state), do: {:reply, state.devices, state}

  def handle_call(
        {:lifecycle, "start"},
        _,
        %{view: %{status: :stopped, reset_required: false}} = state
      ) do
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one, max_restarts: 0)
    owner = self()
    token = make_ref()
    config = state.config
    prepared = state.prepared

    worker =
      spawn_worker(fn ->
        unless prepared, do: build!(config)

        phase =
          if prepared, do: "Booting preserved devices", else: "Bootstrapping configured devices"

        send(owner, {:phase, token, phase})

        devices =
          Map.new(device_configs(config), fn device ->
            device = Map.put(device, :progress, {owner, token})

            {:ok, pid} =
              Supervisor.start_child(
                supervisor,
                Supervisor.child_spec({Device, device}, id: device.id, shutdown: 15_000)
              )

            {device.id, pid}
          end)

        handles = Map.new(devices, fn {id, pid} -> {id, Device.handle(pid)} end)
        send(owner, {:started, token, handles})
      end)

    view = %{
      state.view
      | status: :starting,
        progress: %{},
        phase: if(prepared, do: "Resuming preserved disks", else: "Building shared firmware")
    }

    {:reply, :ok,
     publish(%{state | view: view, supervisor: supervisor, worker: worker, token: token})}
  end

  def handle_call({:lifecycle, "stop"}, _, %{view: %{status: status}} = state)
      when status in [:starting, :ready],
      do: {:reply, :ok, cleanup(state, :stopped, false)}

  def handle_call({:lifecycle, "reset"}, _, %{view: %{status: status}} = state)
      when status in [:stopped, :ready, :failed],
      do: {:reply, :ok, cleanup(state, :stopped, true)}

  def handle_call({:lifecycle, _}, _, state),
    do:
      {:reply,
       {:error, "Lifecycle action unavailable. Wait for cleanup, or Reset after a failure."},
       state}

  @impl true
  def handle_info({:phase, token, phase}, %{token: token} = state),
    do: {:noreply, publish(%{state | view: %{state.view | phase: phase}})}

  def handle_info(
        {:device_phase, token, id, phase},
        %{token: token, view: %{status: :starting}} = state
      ) do
    view = %{state.view | progress: Map.put(state.view.progress, id, phase)}
    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:started, token, devices}, %{token: token, view: %{status: :starting}} = state) do
    clear_worker(state)
    view = %{state.view | status: :ready, phase: "Devices ready", reset_required: false}
    {:noreply, publish(%{state | view: view, devices: devices, worker: nil, prepared: true})}
  end

  def handle_info({:cleaned, token, status, reset?}, %{token: token} = state) do
    clear_worker(state)
    required = not reset? and state.view.reset_required

    phase =
      if status == :failed,
        do: "Simulator operation failed. Inspect diagnostics, then Reset.",
        else:
          "Devices stopped; #{if required, do: "Reset required after interrupted startup", else: "disks preserved"}."

    phase =
      if reset?, do: "Disks erased. Start to build and bootstrap fresh devices.", else: phase

    view = %{state.view | status: status, phase: phase, reset_required: required, progress: %{}}

    {:noreply,
     publish(%{
       state
       | view: view,
         worker: nil,
         supervisor: nil,
         prepared: state.prepared and not reset?
     })}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, %{worker: {pid, ref}} = state) do
    # No retries after an unknown outcome; cleanup is the only automatic action.
    if state.view.status == :stopping do
      view = %{
        state.view
        | status: :unavailable,
          phase: "Cleanup failed. Restart mix dev.",
          reset_required: true
      }

      {:noreply, publish(%{state | worker: nil, view: view})}
    else
      {:noreply, cleanup(%{state | worker: nil}, :failed, false)}
    end
  end

  def handle_info({:EXIT, pid, _}, %{supervisor: pid, view: %{status: status}} = state)
      when status != :stopping,
      do: {:noreply, cleanup(state, :failed, false)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    kill_worker(state)

    if state.supervisor && Process.alive?(state.supervisor),
      do: Supervisor.stop(state.supervisor, :normal, 30_000)
  end

  @impl true
  def format_status(status),
    do: %{
      status
      | state: status.state.view,
        message: :redacted,
        reason: :simulator_failed,
        log: []
    }

  defp cleanup(state, result, reset?) do
    kill_worker(state)
    token = make_ref()
    owner = self()
    supervisor = state.supervisor
    config = state.config

    worker =
      spawn_worker(fn ->
        if supervisor && Process.alive?(supervisor),
          do: Supervisor.stop(supervisor, :normal, :infinity)

        if reset?, do: Enum.each(device_configs(config), &erase_disk!/1)

        send(owner, {:cleaned, token, result, reset?})
      end)

    required = state.view.reset_required or state.view.status == :starting or result == :failed

    view = %{
      state.view
      | status: :stopping,
        phase: if(reset?, do: "Stopping devices and erasing disks", else: "Stopping devices"),
        reset_required: required
    }

    publish(%{state | worker: worker, token: token, devices: %{}, view: view})
  end

  defp erase_disk!(device) do
    case File.rm(Qemu.image_path(device)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "reset disk", path: device.dir
    end
  end

  defp spawn_worker(fun), do: :erlang.spawn_opt(fun, [:link, :monitor])
  defp clear_worker(%{worker: nil}), do: :ok

  defp clear_worker(%{worker: {pid, ref}}) do
    Process.unlink(pid)
    Process.demonitor(ref, [:flush])
  end

  defp kill_worker(%{worker: nil}), do: :ok

  defp kill_worker(%{worker: {pid, _}} = state) do
    clear_worker(state)
    Process.exit(pid, :kill)
  end

  defp publish(state) do
    if state.subscriber, do: send(state.subscriber, {:simulator, state.view})
    state
  end

  defp device_configs(config) do
    config.devices
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index(2)
    |> Enum.map(fn {{id, settings}, index} ->
      true = is_atom(id) and index <= 254
      true = Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(id))
      address = "127.0.0.#{index}"

      Map.merge(settings, %{
        id: id,
        serial: "qemu-#{index}",
        address: address,
        node: :"nerves_gate@#{address}",
        dir: Path.join(config.dir, Atom.to_string(id)),
        firmware: config.firmware,
        factory_firmware: config.factory_firmware
      })
    end)
  end

  defp build!(config) do
    for tool <- ["qemu-system-x86_64", "fwup"], do: true = is_binary(System.find_executable(tool))

    {_, status} =
      MuonTrap.cmd("mix", ["firmware", "--overwrite"],
        env: [
          {"MIX_TARGET", "x86_64"},
          {"MIX_ENV", "dev"},
          {"NERVES_GATE_BACKEND_NODE", nil},
          {"NERVES_GATE_DEVICE_NODE", nil}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("Firmware build failed")
    true = File.regular?(config.firmware) and File.regular?(config.factory_firmware)
  end
end

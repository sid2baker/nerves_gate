defmodule Simulator do
  @moduledoc "Host-only lifecycle owner of disposable QEMU devices. No devices start with this server."
  use GenServer
  alias Simulator.{Device, Qemu}

  @config_header """
  # Ordinary data, not a scenario DSL. The simulator site edits the devices and
  # their Internet wiring. All devices use the same firmware build; set
  # factory_firmware to a compatible older artifact for cross-version work.
  """

  def script(name), do: Path.join(Dev.root(), "priv/simulator/#{name}.exs")
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def subscribe(node), do: GenServer.call({__MODULE__, node}, {:subscribe, self()})
  def lifecycle(node, action), do: GenServer.call({__MODULE__, node}, {:lifecycle, action})
  def configure(node, change), do: GenServer.call({__MODULE__, node}, {:configure, change})
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
    local_project = Path.join(Dev.root(), "firmware")
    local? = config.firmware == :local

    firmware =
      if local?,
        do: Path.join(local_project, "_build/x86_64_dev/nerves/images/nerves_gate.fw"),
        else: Path.expand(config.firmware, Path.dirname(path))

    factory = Path.expand(Map.get(config, :factory_firmware, firmware), Path.dirname(path))

    project =
      if local?,
        do: local_project,
        else:
          config[:firmware_project] && Path.expand(config.firmware_project, Path.dirname(path))

    Map.merge(config, %{
      path: path,
      raw: config,
      dir: dir,
      firmware: firmware,
      factory_firmware: factory,
      firmware_project: project
    })
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    view = %{
      status: :stopped,
      phase: "Simulator empty. Start configured devices to build firmware and boot.",
      devices: device_views(config),
      progress: %{},
      output: nil,
      reset_required: false,
      prepared: false
    }

    {:ok,
     %{
       config: config,
       view: view,
       devices: %{},
       supervisor: nil,
       worker: nil,
       output_timer: nil,
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
        unless prepared, do: build!(config, &send(owner, {:output, token, &1}))

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

    # Map.put: code reload can leave a running simulator with a view from before :output.
    view =
      %{
        state.view
        | status: :starting,
          progress: %{},
          phase: if(prepared, do: "Resuming preserved disks", else: "Building shared firmware")
      }
      |> Map.put(:output, nil)

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

  def handle_call(
        {:configure, change},
        _,
        %{view: %{status: :stopped, reset_required: false}} = state
      ) do
    case change(state.config.devices, change, state.prepared) do
      {:ok, devices} ->
        raw = %{state.config.raw | devices: devices}
        data = raw |> inspect(limit: :infinity) |> Code.format_string!()
        File.write!(state.config.path <> ".tmp", [@config_header, data, "\n"])
        File.rename!(state.config.path <> ".tmp", state.config.path)
        config = %{state.config | raw: raw, devices: devices}
        view = %{state.view | devices: device_views(config)}
        {:reply, :ok, publish(%{state | config: config, view: view})}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:configure, _}, _, state),
    do:
      {:reply,
       {:error, "Stop the devices, or Reset after a failure, before editing configuration."},
       state}

  @impl true
  def handle_info({:phase, token, phase}, %{token: token} = state) do
    state = cancel_output_timer(state)
    {:noreply, publish(%{state | view: Map.put(%{state.view | phase: phase}, :output, nil)})}
  end

  # Keep the latest line even before publishing, so failure cleanup preserves it.
  def handle_info({:output, token, line}, %{token: token} = state) do
    timer = state.output_timer || :erlang.start_timer(250, self(), :build_output)
    {:noreply, %{state | view: Map.put(state.view, :output, line), output_timer: timer}}
  end

  def handle_info({:timeout, timer, :build_output}, %{output_timer: timer} = state),
    do: {:noreply, publish(%{state | output_timer: nil})}

  def handle_info(
        {:device_phase, token, id, phase},
        %{token: token, view: %{status: :starting}} = state
      ) do
    view = %{state.view | progress: Map.put(state.view.progress, id, phase)}
    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:started, token, devices}, %{token: token, view: %{status: :starting}} = state) do
    clear_worker(state)

    view = %{
      state.view
      | status: :ready,
        phase: "Devices ready",
        reset_required: false,
        prepared: true
    }

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

    prepared = state.prepared and not reset?

    view = %{
      state.view
      | status: status,
        phase: phase,
        reset_required: required,
        progress: %{},
        prepared: prepared
    }

    {:noreply, publish(%{state | view: view, worker: nil, supervisor: nil, prepared: prepared})}
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
    state = cancel_output_timer(state)
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
    for path <- [Qemu.image_path(device), Qemu.sd_path(device)] do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "reset disk", path: path
      end
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

  defp cancel_output_timer(state) do
    if state.output_timer, do: Process.cancel_timer(state.output_timer)
    %{state | output_timer: nil}
  end

  defp publish(state) do
    if state.subscriber, do: send(state.subscriber, {:simulator, state.view})
    state
  end

  # Device addresses follow the sorted configuration, and preserved disks keep
  # the serial they were burned with. Adding or removing therefore needs Reset.
  defp change(devices, {:put, id, internet}, prepared) do
    with {:ok, internet} <- port(internet),
         {:ok, id} <- device_id(id),
         true <- Map.has_key?(devices, id) or (not prepared and map_size(devices) < 253) do
      settings = Map.get(devices, id, %{})
      network = settings |> Map.get(:network, %{}) |> Map.put(:internet, internet)
      {:ok, Map.put(devices, id, Map.put(settings, :network, network))}
    else
      false -> {:error, "Reset the devices before adding one; device addresses would change."}
      error -> error
    end
  end

  defp change(devices, {:delete, id}, prepared) do
    case Enum.find(Map.keys(devices), &(Atom.to_string(&1) == id)) do
      nil ->
        {:error, "Unknown device"}

      _ when prepared ->
        {:error, "Reset the devices before removing one; addresses would change."}

      _ when map_size(devices) == 1 ->
        {:error, "Keep at least one device."}

      id ->
        {:ok, Map.delete(devices, id)}
    end
  end

  defp port("lan1"), do: {:ok, :lan1}
  defp port("lan2"), do: {:ok, :lan2}
  defp port(_), do: {:error, "Connect the Internet router to LAN1 or LAN2."}

  defp device_id(id) do
    if Regex.match?(~r/^[a-z][a-z0-9_]{0,31}$/, id) do
      # reach:disable-next-line unsafe_atom_creation -- validated local device IDs
      {:ok, String.to_atom(id)}
    else
      {:error, "Device names use lowercase letters, digits and underscores."}
    end
  end

  defp device_views(config) do
    for device <- device_configs(config) do
      %{
        id: device.id,
        node: device.node,
        address: device.address,
        internet: get_in(device, [:network, :internet]) || :lan1
      }
    end
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

  defp build!(config, report) do
    Simulator.Prerequisites.check!()

    if project = config[:firmware_project] do
      if project == Path.join(Dev.root(), "firmware") do
        Dev.Builds.firmware!("x86_64", report)
      else
        status =
          Simulator.BuildOutput.run(
            "mix",
            ["firmware", "--overwrite"],
            [
              cd: project,
              env: [
                {"MIX_TARGET", "x86_64"},
                {"MIX_ENV", "dev"},
                {"NERVES_GATE_LOCAL_DEPS", "1"},
                {"NERVES_GATE_DEVICE_NODE", nil}
              ]
            ],
            report
          )

        if status != 0 do
          raise "Firmware build failed"
        end
      end
    end

    unless File.regular?(config.firmware) and File.regular?(config.factory_firmware) do
      raise "QEMU firmware image not found. Supply a prebuilt image or run mix setup in the repository."
    end
  end
end

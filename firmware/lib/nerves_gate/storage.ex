defmodule NervesGate.Storage do
  @moduledoc """
  Application-card commissioning, detection and mounting. Insertion never formats
  media. Setup offers use without erasing, skip, or explicitly confirmed ext4
  formatting. Applications remain owned by `NervesGate.Apps`.
  """
  use GenServer
  alias NervesGate.{Error, Observations}
  alias NervesGateSDK.Package
  alias NervesGateSDK.Storage.Status

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def commissioning, do: GenServer.call(__MODULE__, :commissioning)
  def observe, do: Observations.subscribe_runtime(__MODULE__)

  # Apps checks lifecycle admission before handing setup to this domain. All
  # storage work then belongs here, not in a UI process or an RPC worker.
  def setup(action, card_id \\ nil, confirmation \\ nil),
    do: GenServer.call(NervesGate.Apps, {:storage_setup, action, card_id, confirmation})

  @doc false
  def admit(action, card_id, confirmation),
    do: GenServer.call(__MODULE__, {:setup, action, card_id, confirmation})

  def status, do: {:ok, %Status{available?: match?({:ok, _}, root())}}
  def root, do: GenServer.call(__MODULE__, :root)

  def unavailable do
    %{
      available: false,
      choice: :pending,
      present: false,
      filesystem: nil,
      card_id: nil,
      ready: false,
      operation: nil,
      error: nil
    }
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    file = Application.get_env(:nerves_gate, :storage_metadata, "/data/nerves_gate/storage")

    choice =
      case File.read(file) do
        {:ok, "use"} -> :use
        {:ok, "skip"} -> :skip
        _ -> :pending
      end

    send(self(), :poll)
    {:ok, %{file: file, choice: choice, card: card(), worker: nil, error: nil}}
  end

  @impl true
  def handle_call(:commissioning, _, state), do: {:reply, view(state), state}

  def handle_call(:root, _, state) do
    result = if ready?(state), do: {:ok, mountpoint()}, else: {:error, :storage_unavailable}
    {:reply, result, state}
  end

  def handle_call(:observations, _, state),
    do: {:reply, [{Observations.table(), ["storage"]}], state}

  def handle_call({:setup, _, _, _}, _, %{worker: worker} = state) when worker != nil,
    do: {:reply, {:error, :operation_in_progress}, state}

  def handle_call({:setup, :skip, _, _}, _, state) do
    # A regular unmount refuses open files; never silently detach busy apps.
    with :ok <- unmount(), :ok <- save(state.file, :skip) do
      {:reply, :ok, publish(%{state | choice: :skip, error: nil})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:setup, action, card_id, confirmation}, _, state)
      when action in [:use, :format] do
    current = card()

    with true <- current.present and current.card_id == card_id,
         :ok <- allowed(action, current, confirmation),
         :ok <- safe_device() do
      begin_setup(state, action, current)
    else
      false -> {:reply, {:error, :storage_card_changed}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:setup, _, _, _}, _, state),
    do: {:reply, {:error, :storage_setup_invalid}, state}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 1_000)
    current = card()
    state = if current != state.card, do: %{state | card: current, error: nil}, else: state

    if not current.present and device() != nil and root_mount() != nil,
      do: cmd("umount", ["-l", mountpoint()])

    {:noreply, state |> automount() |> publish()}
  end

  def handle_info({ref, result}, %{worker: %{task: %Task{ref: ref} = task}} = state) do
    Process.demonitor(task.ref, [:flush])
    state = %{state | worker: nil, card: card()}

    next =
      case result do
        :ok ->
          case save(state.file, :use) do
            :ok -> %{state | choice: :use, error: nil}
            _ -> %{state | choice: :pending, error: Error.from(:storage_save_failed)}
          end

        {:error, reason} ->
          %{state | error: Error.from(reason)}
      end

    {:noreply, publish(next)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, publish(%{state | worker: nil, error: Error.from(:storage_setup_failed)})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp automount(
         %{choice: :use, worker: nil, error: nil, card: %{present: true, filesystem: "ext4"}} =
           state
       ) do
    if mounted_root?(), do: state, else: start(state, :use)
  end

  defp automount(state), do: state

  defp begin_setup(state, action, current) do
    if action == :use and current.card_id == state.card.card_id and ready?(state) do
      # Repeated non-destructive setup must not unmount a card used by apps.
      {:reply, :ok, state}
    else
      case save(state.file, :pending) do
        :ok -> {:reply, :ok, start(%{state | choice: :pending, card: current}, action)}
        _ -> {:reply, {:error, :storage_save_failed}, state}
      end
    end
  end

  defp start(state, action) do
    id = state.card.card_id
    # Link the worker to this owner so even a forced owner exit closes its
    # MuonTrap port and kills the formatter instead of leaving an orphan.
    task = Task.async(fn -> prepare(action, id) end)
    publish(%{state | worker: %{task: task, action: action}, error: nil})
  end

  defp allowed(:format, _, :erase_all_data), do: :ok
  defp allowed(:format, _, _), do: {:error, :storage_confirmation_required}
  defp allowed(:use, %{filesystem: "ext4"}, _), do: :ok
  defp allowed(:use, _, _), do: {:error, :storage_filesystem}

  defp prepare(action, id) do
    with :ok <- safe_device(),
         :ok <- unmount(),
         true <- card().card_id == id,
         :ok <- maybe_format(action),
         :ok <- File.mkdir_p(mountpoint()),
         :ok <- cmd("mount", ["-t", "ext4", "-o", "nodev,nosuid", device(), mountpoint()]) do
      :ok
    else
      false -> {:error, :storage_card_changed}
      {:error, _} = error -> error
    end
  end

  defp maybe_format(:use), do: :ok

  defp maybe_format(:format) do
    case System.find_executable("mke2fs") do
      nil ->
        {:error, :storage_format_unavailable}

      tool ->
        case MuonTrap.cmd(tool, ["-F", "-t", "ext4", "-L", "apps", device()],
               timeout: 120_000,
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {_, :timeout} -> {:error, :storage_format_timeout}
          _ -> {:error, :storage_format_failed}
        end
    end
  end

  # Reject character devices, system disks and partitions of a mounted system
  # disk. Platform config selects the card; there is no second target mapping.
  defp safe_device do
    with path when is_binary(path) <- device(),
         {:ok, %{type: :device, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o170000) == 0o060000 do
      sys = "/sys/class/block/#{Path.basename(path)}"

      disk =
        if File.exists?(sys <> "/partition"),
          do: sys |> File.read_link!() |> Path.dirname() |> Path.basename(),
          else: Path.basename(path)

      nodes = [
        "/sys/class/block/#{disk}/dev" | Path.wildcard("/sys/class/block/#{disk}/#{disk}*/dev")
      ]

      ids = Enum.map(nodes, &(File.read!(&1) |> String.trim()))
      own_id = File.read!(sys <> "/dev") |> String.trim()

      unsafe? =
        Enum.any?(mounts(), fn mount ->
          (mount.major_minor in ids and mount.mount_point != mountpoint()) or
            (mount.mount_point == mountpoint() and mount.major_minor != own_id)
        end)

      if unsafe?, do: {:error, :storage_in_use}, else: :ok
    else
      _ -> {:error, :storage_card_changed}
    end
  end

  defp card do
    base = %{present: false, card_id: nil, filesystem: nil}

    with path when is_binary(path) <- device(),
         {:ok, %{type: :device} = stat} <- File.stat(path),
         {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        case :file.pread(fd, 0, 2048) do
          {:ok, bytes} when byte_size(bytes) >= 1082 ->
            # Partition sysfs entries have no device/cid; resolve the parent
            # disk's identity. ext4's UUID is stable across ordinary writes.
            sys = "/sys/class/block/#{Path.basename(path)}"

            parent =
              if File.exists?(sys <> "/partition"),
                do: sys |> File.read_link!() |> Path.dirname(),
                else: sys

            cid = File.read(Path.join(parent_sysfs(parent), "device/cid"))

            signature =
              if filesystem(bytes) == "ext4",
                do: binary_part(bytes, 1128, 16),
                else: binary_part(bytes, 0, 512)

            id = :crypto.hash(:sha256, :erlang.term_to_binary({path, stat.inode, cid, signature}))

            %{
              present: true,
              card_id: Base.encode16(id, case: :lower),
              filesystem: filesystem(bytes)
            }

          _ ->
            base
        end
      after
        :file.close(fd)
      end
    else
      _ -> base
    end
  end

  defp parent_sysfs(path), do: Path.expand(path, "/sys/class/block")

  defp filesystem(bytes) do
    cond do
      binary_part(bytes, 1080, 2) == <<83, 239>> -> "ext4"
      binary_part(bytes, 82, 8) == "FAT32   " -> "FAT32"
      binary_part(bytes, 54, 8) in ["FAT16   ", "FAT12   "] -> "FAT"
      true -> "Unknown"
    end
  end

  defp ready?(state),
    do:
      state.choice == :use and state.worker == nil and
        (state.card.present or device() == nil) and mounted_root?()

  defp view(state),
    do:
      Map.merge(state.card, %{
        available: true,
        choice: state.choice,
        ready: ready?(state),
        operation: state.worker && state.worker.action,
        error: state.error
      })

  defp publish(state) do
    Observations.put(["storage"], view(state))
    state
  end

  defp save(file, choice) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file <> ".tmp", Atom.to_string(choice), [:sync]),
         do: File.rename(file <> ".tmp", file)
  end

  defp device, do: Application.get_env(:nerves_gate, :apps_device)
  defp mountpoint, do: Application.get_env(:nerves_gate, :apps_mount, "/mnt/apps")

  defp root_mount, do: Enum.find(mounts(), &(&1.mount_point == mountpoint()))

  defp mounted_root? do
    case root_mount() do
      nil -> false
      mount -> "rw" in mount.mount_options and "rw" in mount.super_options and source?(mount)
    end
  end

  defp source?(mount) do
    case device() do
      # Externally provisioned mount.
      nil ->
        true

      path ->
        File.read("/sys/class/block/#{Path.basename(path)}/dev") ==
          {:ok, mount.major_minor <> "\n"}
    end
  end

  defp unmount do
    if Enum.any?(mounts(), &(&1.mount_point == mountpoint())),
      do: cmd("umount", [mountpoint()]),
      else: :ok
  end

  defp mounts, do: Nerves.Runtime.MountInfo.get_mounts!()

  defp cmd(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, :storage_setup_failed}

      tool ->
        case MuonTrap.cmd(tool, args, timeout: 5_000, stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, :storage_mount_failed}
        end
    end
  end

  def data_dir(app) do
    with true <- Package.valid_name?(app),
         {:ok, root} <- root(),
         {:ok, data} <- directory(root, "data"),
         {:ok, path} <- directory(data, to_string(app)) do
      {:ok, path}
    else
      false -> {:error, :invalid_application}
      error -> error
    end
  end

  @doc false
  def apps_dir do
    with {:ok, root} <- root(), do: directory(root, "apps")
  end

  @doc false
  def directory(parent, name) do
    path = Path.join(parent, name)

    case File.mkdir(path) do
      :ok ->
        {:ok, path}

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %{type: :directory}} -> {:ok, path}
          _ -> {:error, :invalid_directory}
        end

      error ->
        error
    end
  end
end

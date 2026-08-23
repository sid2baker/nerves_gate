defmodule NervesGateQEMU.Runner do
  @moduledoc "Host-only lifecycle and topology control for local NervesGate QEMU devices."

  @default_count 3
  @maximum_count 12

  @type device :: %{
          id: String.t(),
          slug: String.t(),
          index: pos_integer(),
          port: pos_integer(),
          image: Path.t(),
          pidfile: Path.t(),
          qmp_socket: Path.t(),
          serial_socket: Path.t(),
          iframe_url: String.t(),
          status_url: String.t()
        }

  @spec devices() :: [device()]
  def devices do
    manifest()
    |> Map.fetch!("devices")
    |> Enum.map(&device/1)
    |> Enum.sort_by(& &1.index)
  end

  @spec setup(keyword()) :: :ok | {:error, term()}
  def setup(options \\ []) do
    count = Keyword.get(options, :count, @default_count)

    transaction(fn ->
      with :ok <- validate_count(count),
           :ok <- ensure_firmware(),
           previous <- devices(),
           :ok <- remove_devices(previous),
           topology <- new_manifest(count),
           :ok <- write_manifest(topology),
           current <- topology |> Map.fetch!("devices") |> Enum.map(&device/1),
           :ok <- run_script("reset", "all", current),
           :ok <- run_script("start", "all", current) do
        NervesGateQEMU.Fault.clear(:all)
      end
    end)
  end

  @spec scale(pos_integer()) :: :ok | {:error, term()}
  def scale(count) do
    transaction(fn ->
      with :ok <- validate_count(count),
           :ok <- ensure_manifest() do
        scale_to(count)
      end
    end)
  end

  @spec add() :: {:ok, device()} | {:error, term()}
  def add do
    transaction(fn ->
      with :ok <- ensure_manifest(), do: add_device()
    end)
  end

  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(id) do
    transaction(fn ->
      with :ok <- ensure_manifest(),
           {:ok, selected} <- fetch_device(id) do
        remove_selected(selected)
      end
    end)
  end

  @spec start(:all | String.t()) :: :ok | {:error, term()}
  def start(target \\ :all), do: lifecycle("start", target)

  @spec stop(:all | String.t()) :: :ok | {:error, term()}
  def stop(target \\ :all), do: lifecycle("stop", target)

  @spec restart(:all | String.t()) :: :ok | {:error, term()}
  def restart(target \\ :all), do: lifecycle("restart", target)

  @spec reset(:all | String.t()) :: :ok | {:error, term()}
  def reset(target \\ :all), do: lifecycle("reset", target)

  @spec project_root() :: Path.t()
  def project_root, do: Application.fetch_env!(:nerves_gate_qemu, :project_root)

  @spec state_root() :: Path.t()
  def state_root do
    System.get_env("NERVES_GATE_QEMU_STATE", Path.join(project_root(), "tmp/qemu"))
  end

  @spec firmware_path() :: Path.t()
  def firmware_path do
    System.get_env(
      "NERVES_GATE_FIRMWARE",
      Path.join(project_root(), "_build/x86_64_dev/nerves/images/nerves_gate.fw")
    )
  end

  @spec manifest_path() :: Path.t()
  def manifest_path, do: Path.join(state_root(), "topology.json")

  defp lifecycle(action, target) do
    transaction(fn ->
      with :ok <- ensure_manifest(),
           :ok <- maybe_require_firmware(action),
           {:ok, script_target} <- script_target(target),
           :ok <- run_script(action, script_target, devices()) do
        NervesGateQEMU.Fault.clear(target)
      end
    end)
  end

  defp scale_to(count) do
    current = devices()

    cond do
      length(current) == count ->
        :ok

      length(current) < count ->
        case add_device() do
          {:ok, _device} -> scale_to(count)
          {:error, _reason} = error -> error
        end

      true ->
        current
        |> Enum.max_by(& &1.index)
        |> then(&remove_device_without_lock/1)
        |> case do
          :ok -> scale_to(count)
          {:error, _reason} = error -> error
        end
    end
  end

  defp add_device do
    topology = manifest()
    index = Map.fetch!(topology, "next_index")

    cond do
      length(Map.fetch!(topology, "devices")) >= @maximum_count ->
        {:error, {:maximum_devices, @maximum_count}}

      index > 255 ->
        {:error, :device_id_exhausted}

      true ->
        entry = manifest_device(index)
        selected = device(entry)

        previous = topology

        topology = %{
          topology
          | "next_index" => index + 1,
            "devices" => Map.fetch!(topology, "devices") ++ [entry]
        }

        with :ok <- ensure_firmware(),
             :ok <- write_manifest(topology),
             :ok <- run_script("start", selected.id, Enum.map(topology["devices"], &device/1)) do
          {:ok, selected}
        else
          {:error, _reason} = error ->
            run_script("remove", selected.id, Enum.map(topology["devices"], &device/1))
            write_manifest(previous)
            error
        end
    end
  end

  defp remove_device_without_lock(selected), do: remove_selected(selected)

  defp remove_selected(selected) do
    with :ok <- run_script("remove", selected.id, devices()),
         :ok <- NervesGateQEMU.Fault.clear(selected.id) do
      update_devices(&without_device(&1, selected.id))
    end
  end

  defp without_device(entries, id), do: Enum.reject(entries, &(&1["id"] == id))

  defp remove_devices([]), do: :ok
  defp remove_devices(devices), do: run_script("remove", "all", devices)

  defp script_target(:all), do: {:ok, "all"}

  defp script_target(id) when is_binary(id) do
    case fetch_device(id) do
      {:ok, selected} -> {:ok, selected.id}
      {:error, _reason} = error -> error
    end
  end

  defp script_target(_target), do: {:error, :invalid_device}

  defp fetch_device(id) when is_binary(id) do
    normalized = String.upcase(id)

    case Enum.find(devices(), &(&1.id == normalized)) do
      nil -> {:error, :device_not_found}
      selected -> {:ok, selected}
    end
  end

  defp fetch_device(_id), do: {:error, :invalid_device}

  defp run_script(action, target, devices) do
    environment = [{"NERVES_GATE_QEMU_NODES", Enum.map_join(devices, " ", & &1.id)}]

    case System.cmd(script_path(), [action, target],
           env: environment,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if output != "", do: IO.write(output)
        :ok

      {output, status} ->
        {:error, {:qemu_command_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:qemu_command_failed, error}}
  end

  defp ensure_firmware do
    if File.regular?(firmware_path()),
      do: :ok,
      else: {:error, {:firmware_not_found, firmware_path()}}
  end

  defp maybe_require_firmware(action) when action in ["start", "restart", "reset"],
    do: ensure_firmware()

  defp maybe_require_firmware(_action), do: :ok

  defp validate_count(count) when is_integer(count) and count in 1..@maximum_count, do: :ok
  defp validate_count(_count), do: {:error, {:invalid_device_count, 1..@maximum_count}}

  defp update_devices(function) do
    topology = manifest()
    write_manifest(%{topology | "devices" => function.(topology["devices"])})
  end

  defp ensure_manifest do
    case File.read(manifest_path()) do
      {:ok, contents} ->
        case decode_manifest(contents) do
          {:ok, _topology} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, :enoent} ->
        write_manifest(new_manifest(@default_count))

      {:error, reason} ->
        {:error, {:topology_unavailable, reason}}
    end
  end

  defp manifest do
    case File.read(manifest_path()) do
      {:ok, contents} ->
        case decode_manifest(contents) do
          {:ok, topology} -> topology
          {:error, _reason} -> new_manifest(@default_count)
        end

      {:error, _reason} ->
        new_manifest(@default_count)
    end
  end

  defp decode_manifest(contents) do
    case Jason.decode(contents) do
      {:ok, %{"version" => 1, "next_index" => next, "devices" => entries} = topology} ->
        if valid_manifest?(next, entries),
          do: {:ok, topology},
          else: {:error, :invalid_topology_manifest}

      {:ok, _invalid} ->
        {:error, :invalid_topology_manifest}

      {:error, reason} ->
        {:error, {:invalid_topology_manifest, reason}}
    end
  end

  defp valid_manifest?(next, entries) when is_integer(next) and is_list(entries) do
    indexes = Enum.map(entries, &Map.get(&1, "index"))

    next in 1..256 and Enum.uniq(indexes) == indexes and
      Enum.all?(entries, fn
        %{"id" => id, "index" => index} when index in 1..255 ->
          id == manifest_device(index)["id"]

        _invalid ->
          false
      end) and next > Enum.max(indexes, fn -> 0 end)
  end

  defp valid_manifest?(_next, _entries), do: false

  defp write_manifest(topology) do
    path = manifest_path()
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Jason.encode!(topology, pretty: true)) do
      File.rename(temporary, path)
    end
  end

  defp new_manifest(count) do
    %{
      "version" => 1,
      "next_index" => count + 1,
      "devices" => Enum.map(1..count, &manifest_device/1)
    }
  end

  defp manifest_device(index) do
    %{"id" => "M#{index |> Integer.to_string() |> String.pad_leading(2, "0")}", "index" => index}
  end

  defp device(%{"id" => id, "index" => index}) do
    root = state_root()
    slug = String.downcase(id)
    port = 4000 + index

    %{
      id: id,
      slug: slug,
      index: index,
      port: port,
      image: Path.join(root, "#{id}.img"),
      pidfile: Path.join(root, "#{id}.pid"),
      qmp_socket: Path.join(root, "#{id}.qmp.sock"),
      serial_socket: Path.join(root, "#{id}.serial.sock"),
      iframe_url: "http://#{slug}.localhost:#{port}",
      status_url: "http://127.0.0.1:#{port}/api/status"
    }
  end

  defp transaction(function) do
    :global.trans({__MODULE__, state_root()}, function)
  end

  defp script_path, do: Path.join(project_root(), "scripts/qemu.sh")
end

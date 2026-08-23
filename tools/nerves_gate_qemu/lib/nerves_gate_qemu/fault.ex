defmodule NervesGateQEMU.Fault do
  @moduledoc "Host-only semantic fault controls for QEMU uplinks."

  alias NervesGateQEMU.Runner

  @timeout 2_000

  @spec loss(String.t(), number()) :: {:error, :netem_not_configured}
  def loss(_id, _percent), do: {:error, :netem_not_configured}

  @spec latency(String.t(), non_neg_integer()) :: {:error, :netem_not_configured}
  def latency(_id, _milliseconds), do: {:error, :netem_not_configured}

  @spec blackhole(String.t()) :: {:error, :netem_not_configured}
  def blackhole(_id), do: {:error, :netem_not_configured}

  @spec link_down(String.t()) :: :ok | {:error, term()}
  def link_down(id), do: set_link(id, false)

  @spec heal(String.t()) :: :ok | {:error, term()}
  def heal(id), do: set_link(id, true)

  @spec heal_all() :: :ok | {:error, term()}
  def heal_all do
    Runner.devices()
    |> Enum.reduce_while(:ok, fn device, :ok ->
      case heal(device.id) do
        :ok -> {:cont, :ok}
        {:error, :vm_unavailable} -> {:cont, clear(device.id)}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec clear(:all | String.t()) :: :ok | {:error, term()}
  def clear(target), do: state_transaction(fn -> clear_state(target) end)

  defp clear_state(target) do
    case read_faults() do
      {:ok, faults} -> write_faults(cleared_faults(faults, target))
      {:error, _reason} = error -> error
    end
  end

  defp cleared_faults(_faults, :all), do: %{}
  defp cleared_faults(faults, id) when is_binary(id), do: Map.delete(faults, String.upcase(id))

  @spec vm_state(Runner.device()) :: :running | :paused | :stopped | :unknown
  def vm_state(device) do
    case execute(device, "query-status") do
      {:ok, %{"status" => "running"}} -> :running
      {:ok, %{"status" => "paused"}} -> :paused
      {:ok, %{"running" => true}} -> :running
      {:error, :vm_unavailable} -> :stopped
      _other -> :unknown
    end
  end

  @spec link_state(Runner.device()) :: :up | :down | :unknown
  def link_state(device) do
    case status(device) do
      :none -> :up
      :link_down -> :down
      :unknown -> :unknown
    end
  end

  @spec status(Runner.device()) :: :none | :link_down | :unknown
  def status(device) do
    case read_faults() do
      {:ok, faults} ->
        case Map.get(faults, device.id) do
          nil -> :none
          %{"kind" => "link_down"} -> :link_down
          _other -> :unknown
        end

      {:error, _reason} ->
        :unknown
    end
  end

  defp set_link(id, up?) do
    with {:ok, device} <- fetch_device(id),
         {:ok, _result} <-
           execute(device, %{
             "execute" => "set_link",
             "arguments" => %{"name" => "uplink#{device.index}", "up" => up?}
           }) do
      record_link_state(device.id, up?)
    end
  end

  defp record_link_state(id, up?),
    do: state_transaction(fn -> update_link_state(id, up?) end)

  defp update_link_state(id, up?) do
    case read_faults() do
      {:ok, faults} ->
        updated =
          if up?,
            do: Map.delete(faults, id),
            else: Map.put(faults, id, %{"kind" => "link_down"})

        write_faults(updated)

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_device(id) when is_binary(id) do
    normalized = String.upcase(id)

    case Enum.find(Runner.devices(), &(&1.id == normalized)) do
      nil -> {:error, :device_not_found}
      device -> {:ok, device}
    end
  end

  defp fetch_device(_id), do: {:error, :invalid_device}

  defp execute(device, command) when is_binary(command),
    do: execute(device, %{"execute" => command})

  defp execute(device, command) do
    path = String.to_charlist(device.qmp_socket)
    options = [:binary, active: false, packet: :line]

    case :gen_tcp.connect({:local, path}, 0, options, @timeout) do
      {:ok, socket} -> execute_command(socket, command)
      {:error, reason} when reason in [:enoent, :econnrefused] -> {:error, :vm_unavailable}
      {:error, reason} -> {:error, {:qmp_connect_failed, reason}}
    end
  end

  defp execute_command(socket, command) do
    with {:ok, %{"QMP" => _greeting}} <- receive_json(socket),
         :ok <- send_json(socket, %{"execute" => "qmp_capabilities"}),
         {:ok, _capabilities} <- receive_reply(socket),
         :ok <- send_json(socket, command) do
      receive_reply(socket)
    end
  after
    :gen_tcp.close(socket)
  end

  defp send_json(socket, message) do
    :gen_tcp.send(socket, [Jason.encode!(message), "\r\n"])
  end

  defp receive_reply(socket) do
    case receive_json(socket) do
      {:ok, %{"return" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, {:qmp_error, error}}
      {:ok, %{"event" => _event}} -> receive_reply(socket)
      {:ok, response} -> {:error, {:invalid_qmp_response, response}}
      {:error, _reason} = error -> error
    end
  end

  defp receive_json(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout),
         {:ok, decoded} <- Jason.decode(String.trim(line)) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:qmp_receive_failed, reason}}
    end
  end

  defp read_faults do
    case File.read(faults_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, faults} when is_map(faults) -> {:ok, faults}
          {:ok, _invalid} -> {:error, :invalid_fault_state}
          {:error, reason} -> {:error, {:invalid_fault_state, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:fault_state_unavailable, reason}}
    end
  end

  defp write_faults(faults) do
    path = faults_path()
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Jason.encode!(faults, pretty: true)) do
      File.rename(temporary, path)
    end
  end

  defp state_transaction(function) do
    :global.trans({__MODULE__, Runner.state_root()}, function)
  end

  defp faults_path, do: Path.join(Runner.state_root(), "faults.json")
end

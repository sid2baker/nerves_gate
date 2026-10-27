defmodule NervesGate.Recovery.EC100 do
  @moduledoc "EC100 recovery using the BSP's standard Nerves operations."
  alias Nerves.Runtime.MountInfo
  alias NervesGate.Recovery.DataInit

  # One small, boot-lifetime interlock shared with the SSH upload precheck. An
  # admitted upload blocks recovery until reboot, including a failed upload or
  # a pending success callback. A recovery attempt is never retried implicitly.
  @doc false
  def admit(operation, key \\ __MODULE__) do
    :global.trans(
      {{__MODULE__, key}, self()},
      fn ->
        case {:persistent_term.get(key, :idle), operation} do
          {:idle, _} ->
            :persistent_term.put(key, operation)

          {:update, :update} ->
            :ok

          {:update, _} ->
            {:error,
             %{
               code: "firmware_update_pending",
               message: "An SSH firmware upload was admitted. Reboot before recovery."
             }}

          _ ->
            {:error,
             %{
               code: "recovery_already_requested",
               message: "Recovery was already requested. No second attempt was sent."
             }}
        end
      end,
      [node()]
    )
  end

  @doc false
  def firmware_precheck do
    case admit(:update) do
      :ok -> {:ok, []}
      {:error, _} -> {:error, "Recovery requested; firmware uploads blocked until reboot"}
    end
  end

  @doc false
  def data_mounts(mounts, device) do
    mounts
    |> Enum.filter(&(&1.major_minor == device))
    |> Enum.sort_by(&{length(Path.split(&1.mount_point)), &1.mount_id}, :desc)
    |> Enum.map(fn mount ->
      Regex.replace(~r/\\(040|011|012|134)/, mount.mount_point, fn _, octal ->
        <<String.to_integer(octal, 8)>>
      end)
    end)
  end

  # Enabled only by EC100's recovery_adapter. QEMU has no recovery button, and
  # the workstation never starts Indicators or any other device service.
  def execute(action, _) when action in [:reboot, :factory_reset] do
    with :ok <- admit(:recovery), do: recover(action)
  end

  defp recover(:reboot), do: Nerves.Runtime.reboot()

  defp recover(:factory_reset) do
    with :ok <- quiesce(),
         {:ok, data} <- DataInit.check_data(),
         :ok <- unmount_data(data.major_minor) do
      # Default immediate reboot. No separate reboot, cleanup or writer restart
      # after this call, including on an error or an ambiguous timeout.
      case Nerves.Runtime.FwupOps.factory_reset() do
        :ok ->
          :ok

        _ ->
          {:error,
           %{
             code: "factory_reset_incomplete",
             message:
               "Factory reset did not complete. Services remain stopped; no retry was sent."
           }}
      end
    end
  end

  defp quiesce do
    # Supervisor termination leaves writers stopped but keeps Indicators and
    # its worker alive. Stop logger_backends too, so RingLogger cannot write
    # its periodic snapshot after the data partition is unmounted.
    children = [
      NervesGate.Hardware,
      NervesGate.Remote,
      NervesGate.Network,
      NervesGate.SSH
    ]

    apps = [:nerves_ssh, :ssh, :tailscaled_ex, :vintage_net, :nerves_time, :logger_backends]

    with :ok <- stop_all(children, &Supervisor.terminate_child(NervesGate.Supervisor, &1)),
         :ok <- stop_all(apps, &stop_application/1),
         :ok <- stop_history() do
      File.cd("/")
    end
  end

  defp stop_history do
    # Persistent history is disabled ONLY for factory reset. close/1 alone
    # cannot close a disk_log still owned by the serial shell's group process.
    Application.put_env(:kernel, :shell_history, :disabled)

    if Process.whereis(:disk_log_sup) do
      for {_, pid, _, _} <- Supervisor.which_children(:disk_log_sup),
          :disk_log.pid2name(pid) == {:ok, :"$#group_history"} do
        :ok = :sys.terminate(pid, :normal)
      end
    end

    :ok
  end

  defp stop_all(items, stop) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case stop.(item) do
        :ok ->
          {:cont, :ok}

        _ ->
          {:halt,
           {:error,
            %{
              code: "data_quiesce_failed",
              message: "Could not stop data writers. Reset was aborted; services stay stopped."
            }}}
      end
    end)
  end

  defp stop_application(app) do
    case Application.stop(app) do
      :ok -> :ok
      {:error, {:not_started, ^app}} -> :ok
      error -> error
    end
  end

  defp unmount_data(device) do
    result =
      MountInfo.get_mounts!()
      |> data_mounts(device)
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case System.cmd("umount", [path], stderr_to_stdout: true) do
          {_, 0} ->
            {:cont, :ok}

          _ ->
            {:halt,
             {:error,
              %{
                code: "data_unmount_failed",
                message:
                  "Could not unmount all data mounts. Reset was aborted; services stay stopped."
              }}}
        end
      end)

    if result == :ok and data_mounts(MountInfo.get_mounts!(), device) == [],
      do: :ok,
      else:
        {:error,
         %{
           code: "data_unmount_failed",
           message: "Could not unmount all data mounts. Reset was aborted; services stay stopped."
         }}
  end
end

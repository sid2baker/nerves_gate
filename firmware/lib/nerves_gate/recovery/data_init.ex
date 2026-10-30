defmodule NervesGate.Recovery.DataInit do
  @moduledoc false
  alias Nerves.Runtime.MountInfo

  # Nerves.Runtime's supported initialization hook. Run its normal formatter,
  # then fail startup if it silently returned :unmounted/:mounted_with_error.
  # The release starts nerves_runtime as :transient, before data users, so a
  # failure here stops boot instead of allowing writes to a missing data mount.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  def start_link(_) do
    await_first_fwup()
    Nerves.Runtime.Init.init_application_partition()

    with {:ok, _mount} <- check_data(),
         :ok <- NervesGate.Network.Vintage.check_saved_cellular(),
         :ok <- NervesGate.Network.Vintage.prepare_cellular_input() do
      :ignore
    end
  end

  # Nerves.Runtime.KV resolves the active slot through `fwup status` with a fixed
  # one-second call timeout and exits when it expires, which fails this hook and
  # the boot. The first `fwup` run after boot can exceed that while the single
  # guest CPU replays kernel logs. Run it here and wait for it to finish, so
  # KV's own run starts once that startup burst has passed. A status read
  # changes nothing on the device.
  defp await_first_fwup do
    Nerves.Runtime.FwupOps.status()
  catch
    :exit, {:timeout, _} -> :sys.get_state(Nerves.Runtime.FwupOps, 60_000)
  end

  @doc false
  def check_data do
    with {:ok, device} <- File.read(NervesGate.Board.fetch!(:data_partition)) do
      data_mount(MountInfo.get_mounts!(), String.trim(device))
    end
  end

  @doc false
  def data_mount(mounts, device) do
    case Enum.filter(mounts, &(&1.mount_point == "/root")) do
      [%{major_minor: ^device, root: "/", fs_type: "ext4"} = mount] ->
        if Enum.all?(
             [mount.mount_options, mount.super_options],
             &("rw" in &1 and "ro" not in &1)
           ),
           do: {:ok, mount},
           else:
             {:error,
              %{
                code: "data_partition_unavailable",
                message: "The EC100 data partition is not mounted read-write as ext4."
              }}

      _ ->
        {:error,
         %{
           code: "data_partition_unavailable",
           message: "The EC100 data partition is not mounted read-write as ext4."
         }}
    end
  end
end

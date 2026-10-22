defmodule NervesGate.Recovery.DataInit do
  @moduledoc false
  alias Nerves.Runtime.MountInfo

  # Nerves.Runtime's supported initialization hook. Run its normal formatter,
  # then fail startup if it silently returned :unmounted/:mounted_with_error.
  # The release starts nerves_runtime as :transient, before data users, so a
  # failure here stops boot instead of allowing writes to a missing data mount.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  def start_link(_) do
    Nerves.Runtime.Init.init_application_partition()

    with {:ok, _mount} <- check_data(),
         :ok <- NervesGate.Network.Vintage.prepare_cellular_input() do
      :ignore
    end
  end

  @doc false
  def check_data do
    with {:ok, device} <- File.read(Application.fetch_env!(:nerves_gate, :data_partition)) do
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
           else: {:error, :data_partition_unavailable}

      _ ->
        {:error, :data_partition_unavailable}
    end
  end
end

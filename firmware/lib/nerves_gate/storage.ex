defmodule NervesGate.Storage do
  @moduledoc """
  Application storage on a separately mounted SD card. Never formats media.

  When `:apps_device` is configured, `mount/0` mounts that prepared ext4
  filesystem and lazily detaches it after the device disappears. Without it,
  platform provisioning owns the mount. The device boots without a card.
  """
  alias NervesGateSDK.Package
  alias NervesGateSDK.Storage.Status

  def status do
    {:ok, %Status{available?: match?({:ok, _}, root())}}
  end

  def root do
    root = mountpoint()

    if Enum.any?(mounts(), fn mount ->
         mount.mount_point == root and "rw" in mount.mount_options and
           "ro" not in mount.mount_options and "rw" in mount.super_options
       end) do
      {:ok, root}
    else
      {:error, :storage_unavailable}
    end
  end

  @doc false
  def mount do
    device = Application.get_env(:nerves_gate, :apps_device)
    root = mountpoint()
    mounted = Enum.find(mounts(), &(&1.mount_point == root))
    present? = device != nil and match?({:ok, %{type: :device}}, File.stat(device))

    cond do
      device == nil ->
        :ok

      mounted && not present? ->
        # The card was removed; open files fail, and new mounts can proceed.
        cmd("umount", ["-l", root])

      present? and mounted == nil ->
        File.mkdir_p(root)
        # BEAM code and NIFs are loaded from the card, so do not use noexec.
        cmd("mount", ["-t", "ext4", "-o", "nodev,nosuid", device, root])

      true ->
        :ok
    end
  end

  defp mountpoint, do: Application.get_env(:nerves_gate, :apps_mount, "/mnt/apps")

  # Hosts without /proc/self/mountinfo have no card.
  defp mounts do
    case File.read("/proc/self/mountinfo") do
      {:ok, _} -> Nerves.Runtime.MountInfo.get_mounts!()
      {:error, _} -> []
    end
  end

  defp cmd(command, args) do
    case System.find_executable(command) &&
           System.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, :storage_unavailable}
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

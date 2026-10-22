defmodule Dev.Workbench do
  @moduledoc "Shared UI/CLI coordination; QEMU admission stays owned by the simulator."

  def application(action, path, local_sdk \\ false)

  def application("new", path, local_sdk) do
    app = Dev.Applications.new!(path, local_sdk)
    Dev.Applications.open(app.path)
  rescue
    error in [ArgumentError, File.Error] -> {:error, Exception.message(error)}
  end

  def application("open", path, _local_sdk), do: Dev.Applications.open(path)
  def application(_, _, _), do: {:error, "Expected new or open"}

  defdelegate review_firmware(params), to: Dev.Operations
  defdelegate confirm_firmware(id, address), to: Dev.Operations
  defdelegate stop_session(id), to: Dev.Operations
  defdelegate lifecycle(action), to: Dev.Operations
  defdelegate operate(kind, app, device), to: Dev.Operations, as: :start
end

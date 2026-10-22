defmodule DevWeb.WorkbenchLive do
  @moduledoc "Shared operation observation. Work belongs to Dev.Operations, not page processes."
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :workbench_operation, 500)

    socket =
      socket
      |> assign(operation: Dev.Operations.snapshot(), error: nil)
      |> attach_hook(:workbench_operation, :handle_info, fn
        :workbench_operation, socket ->
          Process.send_after(self(), :workbench_operation, 500)
          {:halt, assign(socket, :operation, Dev.Operations.snapshot())}

        _, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  def command(socket, :ok),
    do: {:noreply, assign(socket, error: nil, operation: Dev.Operations.snapshot())}

  def command(socket, {:error, message}), do: {:noreply, assign(socket, :error, message)}
end

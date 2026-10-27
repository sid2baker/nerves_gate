defmodule WorkbenchWeb.Live do
  @moduledoc "Every page observes the current job by subscription; work belongs to Workbench.Jobs."
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _, _, socket) do
    if connected?(socket), do: Workbench.Jobs.subscribe()

    socket =
      socket
      |> assign(job: Workbench.Jobs.snapshot(), error: nil)
      |> attach_hook(:job, :handle_info, fn
        {:jobs, job}, socket -> {:halt, assign(socket, :job, job)}
        _, socket -> {:cont, socket}
      end)

    {:cont, socket}
  end

  def command(socket, :ok), do: {:noreply, assign(socket, :error, nil)}
  def command(socket, {:ok, _}), do: command(socket, :ok)

  def command(socket, {:error, message}) when is_binary(message),
    do: {:noreply, assign(socket, :error, message)}

  def command(socket, {:error, reason}), do: {:noreply, assign(socket, :error, inspect(reason))}
end

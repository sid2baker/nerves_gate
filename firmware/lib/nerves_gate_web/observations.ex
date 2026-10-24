defmodule NervesGateWeb.Observations do
  @moduledoc """
  Bind LiveViews to the device's projection stream. Each view reduces the same
  ordered operations, with separate form drafts. A lost server means unavailable,
  then a fresh subscription snapshot, never continued use of a stale cache.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias NervesGate.Projection
  alias NervesGate.ProjectionServer

  def on_mount(:status, _, _, socket), do: {:cont, subscribe(socket)}

  # The callback receives the new status and the old socket, so editors can
  # update clean fields without losing drafts or their previous observation.
  def subscribe(socket, refresh \\ &assign(&1, :projection, &2), source \\ ProjectionServer) do
    socket =
      socket
      |> assign(
        projection_source: source,
        projection_server: nil,
        projection_monitor: nil,
        projection_retry: nil
      )
      |> initialize()

    Phoenix.LiveView.attach_hook(socket, :observations, :handle_info, fn message, socket ->
      handle_message(message, socket, refresh)
    end)
  end

  defp call(nil, _), do: {:error, :unavailable}

  defp call(source, request) do
    GenServer.call(source, request)
  catch
    :exit, {_, {GenServer, :call, _}} -> {:error, :unavailable}
  end

  defp snapshot(source) do
    case call(source, :snapshot) do
      {:error, _} -> Projection.disconnected()
      projection -> projection
    end
  end

  defp initialize(socket) do
    if Phoenix.LiveView.connected?(socket) do
      bind(socket)
    else
      put_projection(socket, snapshot(socket.assigns.projection_source))
    end
  end

  defp bind(socket) do
    case call(socket.assigns.projection_source, :subscribe) do
      {:ok, pid, projection} ->
        socket
        |> assign(projection_server: pid, projection_monitor: Process.monitor(pid))
        |> put_projection(projection)

      {:error, _} ->
        socket |> put_projection(Projection.disconnected()) |> retry()
    end
  end

  defp handle_message({:projection, pid, operation}, socket, refresh) do
    if pid == socket.assigns.projection_server do
      projection = Projection.apply(socket.assigns.projection_state, operation)
      {:halt, socket |> assign(:projection_state, projection) |> refresh.(projection.status)}
    else
      {:halt, socket}
    end
  end

  defp handle_message({:DOWN, ref, :process, _, _}, socket, refresh)
       when ref == socket.assigns.projection_monitor do
    projection = Projection.disconnected()

    socket =
      socket
      |> assign(projection_server: nil, projection_monitor: nil, projection_state: projection)
      |> refresh.(projection.status)
      |> retry()

    {:halt, socket}
  end

  defp handle_message(:subscribe_projection, socket, refresh) do
    previous = socket.assigns.projection
    socket = socket |> assign(:projection_retry, nil) |> bind()
    status = socket.assigns.projection_state.status
    {:halt, socket |> assign(:projection, previous) |> refresh.(status)}
  end

  defp handle_message(_, socket, _), do: {:cont, socket}

  defp put_projection(socket, projection),
    do: assign(socket, projection_state: projection, projection: projection.status)

  defp retry(%{assigns: %{projection_retry: nil}} = socket) do
    assign(socket, :projection_retry, Process.send_after(self(), :subscribe_projection, 1_000))
  end

  defp retry(socket), do: socket
end

defmodule NervesGateWeb.Observations do
  @moduledoc """
  LiveView lifecycle bindings to domain properties. Only connected views
  subscribe; subscriptions die with the view. Bursts are coalesced and
  payloads never overwrite a newer command reply or a form draft.
  Remote views poll every five seconds and refresh on node up/down events.
  There is no state mirror.
  """
  import Phoenix.Component, only: [assign: 3]

  @backend_node Application.compile_env(:nerves_gate, :backend_node)

  # Read-only pages share this hook. Editors retain their own refresh functions
  # so observation updates never overwrite drafts.
  def on_mount(:status, _, _, socket) do
    {:cont, socket |> subscribe(&refresh_status/1) |> refresh_status()}
  end

  defp refresh_status(socket), do: assign(socket, :projection, NervesGateWeb.Backend.status())

  def subscribe(socket, refresh) do
    if Phoenix.LiveView.connected?(socket) do
      if @backend_node, do: :net_kernel.monitor_nodes(true)

      bind()
    end

    socket
    |> assign(:observation_pending, false)
    |> Phoenix.LiveView.attach_hook(:observations, :handle_info, &handle_message(&1, &2, refresh))
  end

  defp handle_message(message, socket, refresh) do
    case message do
      message when message in [:subscribe_observations, :poll_backend] ->
        bind()
        {:halt, queue(socket)}

      :refresh_observations ->
        {:halt, socket |> assign(:observation_pending, false) |> refresh.()}

      {event, @backend_node} when event in [:nodeup, :nodedown] ->
        {:halt, queue(socket)}

      {event, _} when event in [:nodeup, :nodedown] ->
        {:halt, socket}

      %PropertyTable.Event{} ->
        {:halt, queue(socket)}

      {VintageNet, _, _, _, _} ->
        {:halt, queue(socket)}

      {Tailscale, _, _, _, _} ->
        {:halt, queue(socket)}

      _ ->
        {:cont, socket}
    end
  end

  if @backend_node do
    defp bind, do: Process.send_after(self(), :poll_backend, 5_000)
  else
    defp bind do
      case NervesGate.subscribe() do
        :ok -> :ok
        {:error, _} -> Process.send_after(self(), :subscribe_observations, 1_000)
      end
    end
  end

  defp queue(%{assigns: %{observation_pending: true}} = socket), do: socket

  defp queue(socket) do
    Process.send_after(self(), :refresh_observations, 20)
    assign(socket, :observation_pending, true)
  end
end

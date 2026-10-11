defmodule NervesGateWeb.Observations do
  @moduledoc """
  LiveView lifecycle bindings to domain properties. Only connected views
  subscribe; subscriptions die with the view. Bursts are coalesced and
  payloads never overwrite a newer command reply or a form draft.
  """
  import Phoenix.Component, only: [assign: 3]

  def subscribe(socket, refresh) do
    if Phoenix.LiveView.connected?(socket), do: bind()

    socket
    |> assign(:observation_pending, false)
    |> Phoenix.LiveView.attach_hook(:observations, :handle_info, fn message, socket ->
      case message do
        :subscribe_observations ->
          bind()
          {:halt, queue(socket)}

        :refresh_observations ->
          {:halt, socket |> assign(:observation_pending, false) |> refresh.()}

        %PropertyTable.Event{} ->
          {:halt, queue(socket)}

        {VintageNet, _, _, _, _} ->
          {:halt, queue(socket)}

        {Tailscale, _, _, _, _} ->
          {:halt, queue(socket)}

        _ ->
          {:cont, socket}
      end
    end)
  end

  defp bind do
    case NervesGate.subscribe() do
      :ok -> :ok
      {:error, _} -> Process.send_after(self(), :subscribe_observations, 1_000)
    end
  end

  defp queue(%{assigns: %{observation_pending: true}} = socket), do: socket

  defp queue(socket) do
    Process.send_after(self(), :refresh_observations, 20)
    assign(socket, :observation_pending, true)
  end
end

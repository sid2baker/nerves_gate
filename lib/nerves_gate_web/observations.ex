defmodule NervesGateWeb.Observations do
  @moduledoc """
  LiveView lifecycle bindings to domain properties and application facts.
  Only connected views subscribe. PropertyTable cleans up on process death;
  Phoenix manages application-event subscriptions. Bursts are coalesced and
  payloads never overwrite a newer command reply or a form draft.
  """
  alias NervesGate.Device
  import Phoenix.Component, only: [assign: 3]

  def subscribe(socket, refresh) do
    if Phoenix.LiveView.connected?(socket), do: Device.subscribe()

    for topic <- ["network:events", "remote:events"] do
      Phoenix.LiveView.subscribe(socket, topic, &__MODULE__.handle_event/2)
    end

    socket
    |> assign(:observation_pending, false)
    |> Phoenix.LiveView.attach_hook(:observations, :handle_info, fn message, socket ->
      case message do
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

  @doc false
  def handle_event(_, socket), do: queue(socket)

  defp queue(%{assigns: %{observation_pending: true}} = socket), do: socket

  defp queue(socket) do
    Process.send_after(self(), :refresh_observations, 20)
    assign(socket, :observation_pending, true)
  end
end

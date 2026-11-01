defmodule IotrouterExpansion.UI do
  @moduledoc "Plugin-owned bus controls. Commands run in the supervised plugin controller."
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:status, &status/0)
     |> assign_new(:ports, &ports/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)}
  end

  def render(assigns) do
    ~H"""
    <section class="ui-panel" id="iotrouter-expansion">
      <div class="ui-panel-body">
        <h2>Expansion cards</h2>
        <p class="ui-help">
          Start resets the card chain, so card outputs return to their power-on state. Cards are then discovered and their channels become platform inputs and outputs; control outputs on the I/O page. Supported: digital input and digital output cards. Nothing starts automatically.
        </p>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@status == :unavailable} role="alert">
          Plugin status unavailable. Refresh before continuing.
        </p>
        <p :if={is_map(@status) and @status[:error]} role="alert" id="expansion-error">
          Last start or bus failure: {inspect(@status.error)}
        </p>
        <p :for={port <- @ports} id={"expansion-port-#{port.id}"}>
          {port.label} ({port.id}) — {assignment_label(port)}
          <.link
            :if={port.present? and !assigned?(port)}
            navigate={"/hardware/#{URI.encode_www_form(port.id)}?plugin=iotrouter_expansion"}
            class="ui-button ui-button--secondary"
          >
            Review assignment
          </.link>
        </p>
        <p :if={@ports == []}>No expansion bus on this target.</p>
        <div class="ui-actions">
          <button
            class="ui-button ui-button--primary"
            phx-click="start"
            phx-target={@myself}
            disabled={@uncertain? or running?(@status) or not Enum.any?(@ports, &assigned?/1)}
          >
            Reset and start bus
          </button>
          <button
            class="ui-button ui-button--secondary"
            phx-click="stop"
            phx-target={@myself}
            disabled={@uncertain? or not running?(@status)}
          >
            Stop bus
          </button>
          <button class="ui-button ui-button--secondary" phx-click="refresh" phx-target={@myself}>
            Refresh status
          </button>
        </div>
        <table :if={running?(@status)} id="expansion-cards">
          <thead>
            <tr>
              <th>Address</th><th>Card</th><th>Version</th><th>Channels</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={card <- @status.cards}>
              <td>{card.address}</td>
              <td>{card.name}</td>
              <td>{card.version}</td>
              <td>
                <span :for={{id, value} <- Enum.sort(card.values)}>
                  {id |> String.split(".") |> List.last()}={if value, do: "1", else: "0"}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={running?(@status) and @status.link? == false} class="ui-help">
          The chain's link line is inactive.
        </p>
      </div>
    </section>
    """
  end

  def handle_event("start", _, socket), do: command(socket, &IotrouterExpansion.start/0)
  def handle_event("stop", _, socket), do: command(socket, &IotrouterExpansion.stop/0)

  def handle_event("refresh", _, socket) do
    status = status()

    {:noreply,
     assign(socket,
       status: status,
       ports: ports(),
       uncertain?: status == :unavailable,
       message: nil
     )}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, fun) do
    result = fun.()

    {:noreply,
     assign(socket,
       status: status(),
       ports: ports(),
       message: if(result == :ok, do: nil, else: inspect(result))
     )}
  catch
    :exit, _ ->
      {:noreply,
       assign(socket,
         uncertain?: true,
         message: "Command outcome unknown. Refresh and inspect; no automatic retry."
       )}
  end

  defp running?(%{state: :running}), do: true
  defp running?(_), do: false

  defp assigned?(port),
    do: port.present? and port.enabled? and port.assigned_plugin == "iotrouter_expansion"

  defp assignment_label(port) do
    cond do
      !port.present? -> "Not detected"
      port.assigned_plugin == nil -> "Available for assignment"
      port.assigned_plugin != "iotrouter_expansion" -> "Assigned to #{port.assigned_plugin}"
      !port.enabled? -> "Access disabled"
      true -> "Assigned to this plugin"
    end
  end

  defp ports do
    case IotrouterExpansion.ports() do
      {:ok, ports} -> Enum.filter(ports, &(&1.kind == :iotrouter_expansion))
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp status do
    IotrouterExpansion.status()
  catch
    :exit, _ -> :unavailable
  end
end

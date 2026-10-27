defmodule TailnetSubrouter.UI do
  @moduledoc "App-owned subnet-sharing controls. Commands run in the supervised TailnetSubrouter owner, not this LiveComponent."
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(%{"interface" => "eth1", "address" => "", "prefix" => "24"}, as: :config)
     end)
     |> assign_new(:status, &status/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)}
  end

  def render(assigns) do
    ~H"""
    <section class="ui-panel" id="tailnet-subrouter">
      <div class="ui-panel-body">
        <h2>Share a local subnet</h2>
        <p class="ui-help">Use a dedicated, application-enabled Ethernet interface. Keep USB management available. Configuration adds a temporary address; sharing requires a separate explicit action.</p>
        <p role="status" id="subrouter-state">State: {@status.state}</p>
        <dl :if={@status[:interface]}>
          <dt>Interface</dt><dd>{@status.interface}</dd>
          <dt>Address</dt><dd>{@status.address}/{@status.prefix}</dd>
          <dt>Subnet</dt><dd>{@status.subnet}</dd>
          <dt>Link ready</dt><dd>{if @status.link_ready, do: "Yes", else: "No"}</dd>
          <dt>Advertised</dt><dd>{if @status.advertised, do: "Yes", else: "No"}</dd>
        </dl>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@status[:error]} role="alert">{error_message(@status.error)}</p>
        <.form for={@form} id="subrouter-config" class="ui-stack" phx-submit="configure" phx-target={@myself}>
          <label for="subrouter-interface">Application interface</label>
          <select id="subrouter-interface" name="config[interface]" disabled={@uncertain? or @status.state != :disabled}>
            <option :for={port <- ["eth0", "eth1"]} value={port} selected={@form[:interface].value == port}>{port}</option>
          </select>
          <label for="subrouter-address">Unused gateway-side IPv4 address</label>
          <input id="subrouter-address" name="config[address]" value={@form[:address].value} required placeholder="192.168.50.2" disabled={@uncertain? or @status.state != :disabled} />
          <label for="subrouter-prefix">Subnet prefix length</label>
          <input id="subrouter-prefix" name="config[prefix]" value={@form[:prefix].value} type="number" min="1" max="30" required disabled={@uncertain? or @status.state != :disabled} />
          <button class="ui-button ui-button--primary" disabled={@uncertain? or @status.state != :disabled}>Configure address</button>
        </.form>
        <div class="ui-actions">
          <button class="ui-button ui-button--primary" phx-click="enable" phx-target={@myself} disabled={@uncertain? or @status.state != :configured or !@status[:link_ready]}>Enable sharing</button>
          <button class="ui-button ui-button--secondary" phx-click="disable" phx-target={@myself} disabled={@uncertain? or @status.state == :disabled}>Disable and release</button>
          <button class="ui-button ui-button--secondary" phx-click="refresh" phx-target={@myself}>Refresh status</button>
        </div>
        <p class="ui-help">Approve the advertised subnet in the Tailscale admin console and permit it in tailnet policy. Advertisement does not prove approval or reachability. Configuration is not replayed after restart.</p>
      </div>
    </section>
    """
  end

  def handle_event("configure", %{"config" => config}, socket) do
    socket =
      assign(
        socket,
        :form,
        to_form(Map.take(config, ["interface", "address", "prefix"]), as: :config)
      )

    case Integer.parse(config["prefix"] || "") do
      {prefix, ""} when prefix in 1..30 ->
        command(socket, fn ->
          TailnetSubrouter.configure(config["interface"], config["address"], prefix)
        end)

      _ ->
        {:noreply, assign(socket, :message, "Enter a subnet prefix length from 1 to 30.")}
    end
  end

  def handle_event("enable", _, socket), do: command(socket, &TailnetSubrouter.enable/0)
  def handle_event("disable", _, socket), do: command(socket, &TailnetSubrouter.disable/0)

  def handle_event("refresh", _, socket) do
    state = status()

    {:noreply,
     assign(socket, status: state, uncertain?: state.state == :unavailable, message: nil)}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, operation) do
    case operation.() do
      :ok ->
        {:noreply, assign(socket, status: status(), message: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, status: status(), message: error_message(reason))}
    end
  catch
    :exit, _ ->
      {:noreply,
       assign(socket,
         uncertain?: true,
         message:
           "Command outcome unknown. Refresh status before another command; nothing will be retried automatically."
       )}
  end

  defp status do
    TailnetSubrouter.status()
  catch
    :exit, _ -> %{state: :unavailable}
  end

  defp error_message(%{message: message}) when is_binary(message), do: message

  defp error_message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp error_message(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp error_message(_), do: "Operation failed. Inspect gateway status before continuing."
end

defmodule TailnetSubrouter.UI do
  @moduledoc "Plugin-owned subnet-sharing controls. Commands run in the supervised TailnetSubrouter owner, not this LiveComponent."
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:interfaces, &interfaces/0)
     |> then(fn socket ->
       assign_new(socket, :form, fn ->
         selected = Enum.find(ports(socket.assigns.interfaces), &(unavailable_reason(&1) == nil))

         to_form(
           %{
             "interface" => if(selected, do: selected.id, else: ""),
             "address" => "",
             "prefix" => "24"
           },
           as: :config
         )
       end)
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
        <p class="ui-help">Assign a dedicated LAN here before entering address settings. Keep USB management available. Configuration adds a temporary address; sharing requires a separate explicit action.</p>
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
        <section :if={@status.state == :disabled} id="subrouter-assignments">
          <h3>1. Choose a dedicated LAN</h3>
          <p class="ui-help">Assignment review is owned by the gateway and may stop this plugin. Address drafts are volatile: the links below discard any unsaved address draft. Assign first, return here, then configure.</p>
          <p :for={port <- ports(@interfaces)}>
            {port.id} — {unavailable_reason(port) || "Assigned and available"}
            <.link :if={!port.internet? and (port.assigned_plugin != "tailnet_subrouter" or !port.plugin_enabled?)} navigate={assignment_path(port.id)} class="ui-button ui-button--secondary">Discard draft and review assignment</.link>
          </p>
          <h3>2. Configure address</h3>
        </section>
        <.form for={@form} id="subrouter-config" class="ui-stack" phx-change="edit_config" phx-submit="configure" phx-target={@myself}>
          <label for="subrouter-interface">Plugin interface</label>
          <select id="subrouter-interface" name="config[interface]" disabled={@uncertain? or @status.state != :disabled}>
            <option value="" selected={@form[:interface].value == ""}>Select an available interface</option>
            <option :for={port <- ports(@interfaces)} value={port.id} selected={@form[:interface].value == port.id} disabled={unavailable_reason(port) != nil}>{port.id}{if reason = unavailable_reason(port), do: " — #{reason}"}</option>
          </select>
          <p :if={match?({:error, _}, @interfaces)} class="ui-help">Interface status is unavailable. Refresh status before configuring.</p>
          <p :if={match?({:ok, _}, @interfaces) and not Enum.any?(ports(@interfaces), &(unavailable_reason(&1) == nil)) and @status.state == :disabled} class="ui-help">No assigned interface is available. Use the assignment review above; keep the Internet port unchanged. Return here after assignment.</p>
          <label for="subrouter-address">Unused gateway-side IPv4 address</label>
          <input id="subrouter-address" name="config[address]" value={@form[:address].value} required placeholder="192.168.50.2" disabled={@uncertain? or @status.state != :disabled} />
          <label for="subrouter-prefix">Subnet prefix length</label>
          <input id="subrouter-prefix" name="config[prefix]" value={@form[:prefix].value} type="number" min="1" max="30" required disabled={@uncertain? or @status.state != :disabled} />
          <button class="ui-button ui-button--primary" disabled={@uncertain? or @status.state != :disabled or not selectable?(@interfaces, @form[:interface].value)}>Configure address</button>
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

  def handle_event("edit_config", %{"config" => config}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Map.take(config, ["interface", "address", "prefix"]), as: :config)
     )}
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
        if selectable?(socket.assigns.interfaces, config["interface"]) do
          command(socket, fn ->
            TailnetSubrouter.configure(config["interface"], config["address"], prefix)
          end)
        else
          {:noreply,
           assign(
             socket,
             :message,
             "Select an available plugin interface. Refresh status if settings changed."
           )}
        end

      _ ->
        {:noreply, assign(socket, :message, "Enter a subnet prefix length from 1 to 30.")}
    end
  end

  def handle_event("enable", _, socket), do: command(socket, &TailnetSubrouter.enable/0)
  def handle_event("disable", _, socket), do: command(socket, &TailnetSubrouter.disable/0)

  def handle_event("refresh", _, socket) do
    state = status()

    {:noreply,
     assign(socket,
       status: state,
       interfaces: interfaces(),
       uncertain?: state.state == :unavailable,
       message: nil
     )}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, operation) do
    case operation.() do
      :ok ->
        {:noreply, assign(socket, status: status(), interfaces: interfaces(), message: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           status: status(),
           interfaces: interfaces(),
           message: error_message(reason)
         )}
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

  defp interfaces do
    TailnetSubrouter.interfaces()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp ports({:ok, interfaces}),
    do: Enum.filter(interfaces, &(&1.kind == :ethernet and &1.id in ["eth0", "eth1"]))

  defp ports(_), do: []

  defp unavailable_reason(port) do
    cond do
      port.internet? -> "Used for Internet"
      port.claimed? -> "Already claimed"
      port.assigned_plugin != "tailnet_subrouter" -> "Not assigned to this plugin"
      not port.plugin_enabled? -> "Disabled under Hardware"
      port.addresses != [] -> "Already has an address"
      true -> nil
    end
  end

  defp assignment_path("eth0"), do: "/hardware/lan/1?plugin=tailnet_subrouter"
  defp assignment_path("eth1"), do: "/hardware/lan/2?plugin=tailnet_subrouter"

  defp selectable?(interfaces, id),
    do: Enum.any?(ports(interfaces), &(&1.id == id and unavailable_reason(&1) == nil))

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

defmodule NervesGateWeb.SetupLive do
  use Phoenix.LiveView
  alias NervesGate.{Config, Network}
  import NervesGateWeb.NetworkStatus

  def mount(_, _, socket) do
    if connected?(socket) do
      Network.subscribe()
      Process.send_after(self(), :tick, 1_000)
    end

    status = Network.status()

    network =
      if status.trial,
        do: status.trial.network,
        else: (status.config || Config.defaults())["network"]

    {:ok,
     assign(socket,
       status: status,
       form: to_form(network, as: :network),
       step: :welcome,
       message: nil,
       now: System.system_time(:millisecond)
     )}
  end

  def handle_event("begin", _, socket),
    do: {:noreply, assign(socket, step: :address, message: nil)}

  def handle_event("change", %{"network" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params, as: :network), message: nil)}

  def handle_event("review", %{"network" => params}, socket) do
    case Config.validate_network(params) do
      {:ok, network} ->
        {:noreply,
         assign(socket, form: to_form(network, as: :network), step: :review, message: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, message: reason)}
    end
  end

  def handle_event("apply", _, %{assigns: %{step: :review}} = socket) do
    case Network.propose(socket.assigns.form.params) do
      {:ok, _} ->
        {:noreply, assign(socket, status: Network.status(), message: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, status: Network.status(), message: error_message(reason))}
    end
  end

  def handle_event("confirm", _, socket) do
    case socket.assigns.status.trial do
      %{id: id} ->
        case Network.confirm(id) do
          :ok ->
            {:noreply, assign(socket, status: Network.status(), step: :done, message: nil)}

          {:error, reason} ->
            {:noreply, assign(socket, status: Network.status(), message: error_message(reason))}
        end

      nil ->
        {:noreply, assign(socket, message: "This trial has ended. Review your settings again.")}
    end
  end

  def handle_event("cancel", _, socket) do
    if socket.assigns.status.trial, do: Network.cancel(socket.assigns.status.trial.id)

    {:noreply,
     assign(socket,
       status: Network.status(),
       step: :address,
       message: "Previous settings restored."
     )}
  end

  def handle_info({:network, status}, socket), do: {:noreply, assign(socket, status: status)}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, now: System.system_time(:millisecond))}
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold">Welcome to Nerves Gate</h1>
    <p>Setup runs entirely on this gateway. You do not need internet or a SIM card.</p>
    <p class="alert alert-warning hidden phx-disconnected:block" role="alert">
      Connection lost. Unconfirmed changes will still roll back. Reconnect to the previous address after 60 seconds.
    </p>
    <.topology status={@status} />
    <p :if={@message} class="alert alert-warning" role="alert">{@message}</p>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <%= cond do %>
          <% @status.config == nil -> %>
            <h2 class="card-title">Saved settings need attention</h2>
            <p>
              The configuration could not be read. It has not been overwritten. Use recovery SSH or serial to inspect /data/nerves_gate.json.
            </p>
          <% @status.trial != nil -> %>
            <h2 class="card-title">Can you still reach the gateway?</h2>
            <p>
              Check that your equipment is reachable, then keep these settings. Otherwise the previous settings return automatically.
            </p>
            <p role="timer">
              Reverting in {max(0, div(@status.trial.expires_at - @now + 999, 1000))} seconds.
            </p>
            <p :if={@status.trial.network["ip_method"] == "static"}>
              The new local IP is <strong>{@status.trial.network["static_ip"]}</strong>. Reopen this page there if your Ethernet connection drops.
            </p>
            <p :if={!@status.ready}>
              Waiting for an Ethernet link and the requested address on the bridge.
            </p>
            <div class="card-actions">
              <button
                id="confirm-settings"
                phx-click="confirm"
                disabled={!@status.ready}
                class="btn btn-primary"
              >Keep these settings</button>
              <button phx-click="cancel" class="btn btn-outline">Restore previous settings</button>
            </div>
          <% @step == :welcome -> %>
            <h2 class="card-title">Connect your equipment</h2>
            <p>
              Use either Ethernet port. Both belong to the same local network; your equipment keeps its existing IP addresses.
            </p>
            <p>4G and remote access will be configured in a later software milestone.</p>
            <button phx-click="begin" class="btn btn-primary w-fit">Configure local access</button>
          <% @step == :address -> %>
            <h2 class="card-title">How should this gateway get its local address?</h2>
            <.form
              for={@form}
              id="network-form"
              phx-change="change"
              phx-submit="review"
              class="space-y-4"
            >
              <label class="form-control block">
                <span>Address assignment</span>
                <select
                  name="network[ip_method]"
                  class="select select-bordered block"
                  aria-label="Address assignment"
                >
                  <option value="dhcp" selected={@form.params["ip_method"] == "dhcp"}>
                    Automatic (DHCP)
                  </option>
                  <option value="static" selected={@form.params["ip_method"] == "static"}>
                    Use a specific address
                  </option>
                </select>
              </label>
              <p :if={@form.params["ip_method"] == "dhcp"}>
                Your existing router assigns the address. Nerves Gate never hands out addresses on Ethernet.
              </p>
              <div :if={@form.params["ip_method"] == "static"} class="space-y-3">
                <label class="block">Gateway's local IP<input
                  class="input input-bordered block"
                  name="network[static_ip]"
                  value={@form.params["static_ip"]}
                  placeholder="192.168.1.10"
                  required
                /></label>
                <label class="block">Subnet mask<input
                  class="input input-bordered block"
                  name="network[subnet_mask]"
                  value={@form.params["subnet_mask"]}
                  placeholder="255.255.255.0"
                  required
                /></label>
                <label class="block">Router address (optional)<input
                  class="input input-bordered block"
                  name="network[gateway]"
                  value={@form.params["gateway"]}
                  placeholder="192.168.1.1"
                /></label>
                <p>
                  Choose an unused address in your equipment's network. Ask your network administrator if unsure.
                </p>
              </div>
              <button class="btn btn-primary">Review settings</button>
            </.form>
          <% @step == :review -> %>
            <h2 class="card-title">Review before changing anything</h2>
            <p>
              Local address: {if @form.params["ip_method"] == "dhcp",
                do: "Automatic (DHCP)",
                else: @form.params["static_ip"] <> " / " <> @form.params["subnet_mask"]}
            </p>
            <p>Router: {@form.params["gateway"] || "Not specified"}</p>
            <p>
              Changing the address may disconnect this browser. Keep serial or a separate recovery connection available. Settings are saved only after you confirm within 60 seconds.
            </p>
            <div class="card-actions">
              <button
                id="apply-settings"
                phx-click="apply"
                disabled={@status.recovering}
                class="btn btn-primary"
              >Try for 60 seconds</button>
              <button phx-click="begin" class="btn btn-outline">Edit settings</button>
            </div>
          <% @step == :done -> %>
            <h2 class="card-title">Local setup complete</h2>
            <p>Your confirmed settings are saved and will survive a restart.</p>
            <a href="/" class="btn btn-primary w-fit">Open dashboard</a>
        <% end %>
      </div>
    </section>
    <a href="/" class="link">Back to dashboard</a>
    """
  end

  defp error_message(:not_connected),
    do: "The bridge is not ready yet. Check the Ethernet cable and address."

  defp error_message(:expired), do: "The trial expired. Previous settings are being restored."
  defp error_message(:trial_in_progress), do: "Another browser already started a trial."

  defp error_message(:recovery_in_progress),
    do: "Wait for saved settings to be restored before trying again."

  defp error_message(reason), do: "Settings were not saved: #{inspect(reason)}"
end

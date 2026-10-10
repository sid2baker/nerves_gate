defmodule NervesGateWeb.SetupLive do
  use Phoenix.LiveView
  alias NervesGate.Device
  import NervesGateWeb.NetworkStatus

  def mount(_, _, socket) do
    subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)

    projection = Device.projection()
    network = projection.network

    settings =
      if network.pending do
        network.pending.network
      else
        network.desired || network.defaults
      end

    {:ok,
     assign(socket,
       projection: projection,
       form: to_form(settings, as: :network),
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
    case Device.dispatch("network.validate", %{"network" => params}) do
      {:ok, %{result: %{network: network}, projection: projection}} ->
        {:noreply,
         assign(socket,
           projection: projection,
           form: to_form(network, as: :network),
           step: :review,
           message: nil
         )}

      {:error, %{error: error, projection: projection}} ->
        {:noreply, assign(socket, projection: projection, message: error.message)}
    end
  end

  def handle_event("apply", %{"revision" => revision}, %{assigns: %{step: :review}} = socket) do
    result =
      Device.dispatch("network.propose", %{"network" => socket.assigns.form.params},
        expected_revision: revision
      )

    command_reply(socket, result, [])
  end

  def handle_event("apply", _, socket),
    do: {:noreply, assign(socket, message: "Review your settings before applying them.")}

  def handle_event("confirm", params, socket) do
    command_reply(socket, Device.dispatch("network.confirm", Map.take(params, ["trial_id"])),
      step: :done
    )
  end

  def handle_event("cancel", params, socket) do
    command_reply(socket, Device.dispatch("network.cancel", Map.take(params, ["trial_id"])),
      step: :address,
      message: "Restoring previous settings."
    )
  end

  @doc false
  def handle_device({:device, _projection}, socket) do
    # A notification queued before a command reply may be older than that reply.
    assign(socket, projection: Device.projection())
  end

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
    <.topology status={@projection.network} />
    <p :if={@message} class="alert alert-warning" role="alert">{@message}</p>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <%= cond do %>
          <% !@projection.network.available -> %>
            <h2 class="card-title">Network control is restarting</h2>
            <p>Wait for the device to reconnect. Unconfirmed settings still roll back.</p>
          <% @projection.network.desired == nil -> %>
            <h2 class="card-title">Saved settings need attention</h2>
            <p>
              The configuration could not be read. It has not been overwritten. Use recovery SSH or serial to inspect /data/nerves_gate.json.
            </p>
          <% @projection.network.pending != nil -> %>
            <h2 class="card-title">Can you still reach the gateway?</h2>
            <p>
              Check that your equipment is reachable, then keep these settings. Otherwise the previous settings return automatically.
            </p>
            <p role="timer">
              Reverting in {max(0, div(@projection.network.pending.expires_at - @now + 999, 1000))} seconds.
            </p>
            <p :if={@projection.network.pending.network["ip_method"] == "static"}>
              The new local IP is <strong>{@projection.network.pending.network["static_ip"]}</strong>. Reopen this page there if your Ethernet connection drops.
            </p>
            <p :if={!@projection.actions["network.confirm"].enabled}>
              {@projection.actions["network.confirm"].reason.message}
            </p>
            <div class="card-actions">
              <button
                id="confirm-settings"
                phx-click="confirm"
                phx-value-trial_id={@projection.network.pending.id}
                disabled={!@projection.actions["network.confirm"].enabled}
                class="btn btn-primary"
              >Keep these settings</button>
              <button
                phx-click="cancel"
                phx-value-trial_id={@projection.network.pending.id}
                disabled={!@projection.actions["network.cancel"].enabled}
                class="btn btn-outline"
              >Restore previous settings</button>
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
            <p :if={!@projection.actions["network.propose"].enabled}>
              {@projection.actions["network.propose"].reason.message}
            </p>
            <div class="card-actions">
              <button
                id="apply-settings"
                phx-click="apply"
                phx-value-revision={@projection.revision}
                disabled={!@projection.actions["network.propose"].enabled}
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

  defp command_reply(socket, {:ok, %{projection: projection}}, assigns) do
    {:noreply, socket |> assign(projection: projection, message: nil) |> assign(assigns)}
  end

  defp command_reply(socket, {:error, %{error: error, projection: projection}}, _) do
    {:noreply, assign(socket, projection: projection, message: error.message)}
  end
end

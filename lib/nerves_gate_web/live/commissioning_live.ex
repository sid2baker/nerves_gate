defmodule NervesGateWeb.CommissioningLive do
  @moduledoc "Commissions a gateway or applies one guarded settings change."

  use NervesGateWeb, :live_view

  import NervesGateWeb.GatewayComponents

  alias NervesGateWeb.FormHelpers

  @steps [:internet, :tailnet, :cluster]
  @default_revert_minutes 1
  @maximum_revert_minutes 60

  @impl true
  def mount(_params, web_session, socket) do
    mount_editor(
      socket,
      connection_id(),
      Map.get(web_session, "tailnet_access", false)
    )
  end

  defp mount_editor(socket, connection_id, tailnet_access) do
    {:ok, session, fleet} = NervesGate.connect()
    snapshot = fleet.local
    status = snapshot.state.configuration
    mode = if status.configured, do: :settings, else: :editor

    socket =
      socket
      |> assign(
        connection_id: connection_id,
        tailnet_access: tailnet_access,
        mode: mode,
        editor_step: current_step(status),
        tick_timer: nil,
        public_snapshot: snapshot,
        revert_minutes: @default_revert_minutes,
        revert_timeout:
          if(status.configured, do: :timer.minutes(@default_revert_minutes), else: nil)
      )
      |> assign_private(
        session: session,
        session_monitor: Process.monitor(session)
      )
      |> refresh(snapshot)
      |> schedule_tick()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen">
      <div
        id="gateway-reconnecting-notification"
        role="status"
        aria-live="assertive"
        class="fixed inset-x-4 top-4 z-50 hidden rounded-2xl border border-sky-400/25 bg-zinc-950/95 p-5 text-sm text-sky-300 shadow-xl shadow-black/10 backdrop-blur-sm phx-disconnected:block sm:right-6 sm:left-auto sm:w-full sm:max-w-md"
      >
        <p class="font-bold text-white">Connection interrupted — reconnecting…</p>
        <p class="mt-2 leading-6">
          This is expected while Internet or Tailnet settings change. If the gateway does not
          return, the temporary settings will revert automatically.
        </p>
      </div>

      <div :if={@mode == :settings} class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <header class="flex flex-col gap-4 border-b border-white/10 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">Connection settings</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
              Nothing changes until you press an Update button. Every update is temporary until
              it is kept from a fresh Tailnet connection.
            </p>
          </div>
          <.link_button href={~p"/"} class="shrink-0">Back to status</.link_button>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <aside
          :if={@configuration.pending}
          id="temporary-settings-notification"
          role="status"
          aria-live="assertive"
          class="fixed inset-x-4 top-4 z-50 rounded-2xl border border-amber-400/25 bg-zinc-950/95 p-5 shadow-xl shadow-black/10 backdrop-blur-sm sm:right-6 sm:left-auto sm:w-full sm:max-w-md"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.18em] text-amber-300">
                Temporary changes
              </p>
              <h2 class="mt-1 text-xl font-semibold text-white">
                {settings_scope_label(@configuration.pending.scope)} update applied
              </h2>
            </div>
            <.badge tone={:warning} class="shrink-0">
              {duration(@configuration.pending.remaining_seconds || 0)}
            </.badge>
          </div>
          <p class="mt-3 text-sm leading-6 text-zinc-300">
            Keep these changes before the timer expires, or the gateway will restore the accepted
            settings automatically.
          </p>
          <p
            :if={connection_critical_scope?(@configuration.pending.scope)}
            class="mt-2 text-sm leading-6 text-amber-200"
          >
            Internet or Tailnet changes can briefly interrupt this page. Seeing this notification
            means the browser has reached the gateway again.
          </p>
          <div class="mt-4 flex flex-wrap gap-3">
            <.button
              :if={@tailnet_access}
              phx-click="keep-settings"
              phx-value-id={@configuration.pending.id}
            >
              Keep changes
            </.button>
            <.link_button
              :if={not @tailnet_access and @view.settings_url}
              href={@view.settings_url}
            >
              Reopen through Tailnet
            </.link_button>
            <.button
              phx-click="revert-configuration"
              phx-value-id={@configuration.pending.id}
              tone={:danger}
            >
              Revert changes
            </.button>
          </div>
        </aside>

        <.card :if={is_nil(@configuration.pending)} class="mt-6">
          <form id="rollback-timeout-form" phx-change="set-revert-timeout">
            <label class="grid gap-2 text-sm font-medium text-zinc-300 sm:grid-cols-[1fr_auto] sm:items-center">
              <span>
                <span class="block text-zinc-100">Revert unless kept after</span>
                <span class="mt-1 block text-xs font-normal leading-5 text-zinc-500">
                  This timer applies to every Update button on this page.
                </span>
              </span>
              <select
                name="revert_minutes"
                disabled={not is_nil(@configuration.pending)}
                class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70 disabled:cursor-not-allowed disabled:opacity-40"
              >
                <option
                  :for={minutes <- [1, 2, 3, 5, 10, 15, 30, 60]}
                  value={minutes}
                  selected={@revert_minutes == minutes}
                >
                  {minutes_label(minutes)}
                </option>
              </select>
            </label>
          </form>
        </.card>

        <div class="mt-6 grid gap-6">
          <.card>
            <.section_header
              eyebrow="Internet"
              title="Uplink and display name"
              description="Update and verify the gateway's Internet connection."
            />
            <form id="internet-settings-form" phx-submit="update-internet-settings" class="mt-6">
              <fieldset
                disabled={not is_nil(@configuration.pending)}
                class="grid gap-5 disabled:opacity-40"
              >
                <input type="hidden" name="revert_minutes" value={@revert_minutes} />
                <.input
                  label="Gateway display name"
                  name="device[name]"
                  value={@configuration.current.name}
                  maxlength="80"
                  required
                  hint={gateway_name_hint()}
                />
                <label class="grid gap-2 text-sm font-medium text-zinc-300">
                  <span>Addressing</span>
                  <select
                    id="settings-internet-method"
                    name="internet[method]"
                    aria-controls="settings-static-fields"
                    aria-expanded={to_string(network_method(@configuration.current) == :static)}
                    data-internet-method
                    phx-hook="InternetMethod"
                    class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70"
                  >
                    <option value="dhcp" selected={network_method(@configuration.current) == :dhcp}>DHCP (automatic)</option>
                    <option value="static" selected={network_method(@configuration.current) == :static}>Static IPv4</option>
                  </select>
                </label>
                <div
                  id="settings-static-fields"
                  data-static-internet-fields
                  hidden={network_method(@configuration.current) != :static}
                  class="grid gap-4 sm:grid-cols-2"
                >
                  <.input label="IP address" name="internet[ip_address]" value={network_value(@configuration.current, :address)} />
                  <.input label="Prefix length" name="internet[prefix_length]" value={network_value(@configuration.current, :prefix_length)} />
                  <.input label="Gateway" name="internet[gateway]" value={network_value(@configuration.current, :gateway)} />
                  <.input label="DNS resolver" name="internet[dns]" value={network_value(@configuration.current, :dns_primary)} />
                </div>
                <.connection_pause_notice scope={:internet} timeout={@revert_minutes} />
                <.button type="submit" phx-disable-with="Applying Internet settings…">
                  Update Internet
                </.button>
              </fieldset>
            </form>
          </.card>

          <.card>
            <.section_header
              eyebrow="Tailnet"
              title="Tailnet enrollment"
              description="Leave the key blank to keep the current profile, or provide a new key to switch profiles temporarily."
            />
            <form id="tailnet-settings-form" phx-submit="update-tailnet-settings" class="mt-6">
              <fieldset
                disabled={not is_nil(@configuration.pending)}
                class="grid gap-5 disabled:opacity-40"
              >
                <input type="hidden" name="revert_minutes" value={@revert_minutes} />
                <.input
                  label="Tailscale auth key"
                  name="auth_token"
                  type="password"
                  autocomplete="off"
                  hint="The key is used once and is never persisted."
                />
                <.connection_pause_notice scope={:tailnet} timeout={@revert_minutes} />
                <.button type="submit" phx-disable-with="Applying Tailnet settings…">
                  Update Tailnet
                </.button>
              </fieldset>
            </form>
          </.card>

          <.card>
            <.section_header
              eyebrow="Cluster"
              title="Cluster group"
              description="Change the public group used for automatic gateway connections."
            />
            <form id="cluster-settings-form" phx-submit="update-cluster-settings" class="mt-6">
              <fieldset
                disabled={not is_nil(@configuration.pending)}
                class="grid gap-5 disabled:opacity-40"
              >
                <input type="hidden" name="revert_minutes" value={@revert_minutes} />
                <.input
                  label="Cluster group"
                  name="cluster[group]"
                  value={@configuration.current.cluster_group}
                  list="settings-cluster-groups"
                  maxlength="128"
                  pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
                />
                <datalist id="settings-cluster-groups">
                  <option :for={group <- @view.cluster.groups} value={group.name}>{group.members} visible gateway(s)</option>
                </datalist>
                <.button type="submit" phx-disable-with="Applying Cluster settings…">
                  Update Cluster
                </.button>
              </fieldset>
            </form>
          </.card>
        </div>
      </div>

      <div :if={@mode == :editor} class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <header class="flex flex-col gap-4 border-b border-white/10 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">Configure gateway</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
              {change_description(@configuration)}
            </p>
          </div>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <ol
          class="mt-7 grid grid-cols-3 gap-1"
          aria-label="Commissioning progress"
        >
          <li
            :for={{phase, index} <- Enum.with_index(@steps, 1)}
            aria-current={if @editor_step == phase, do: "step"}
            class={[
              "border-b-2 px-1 pb-3 text-center text-[10px] font-bold uppercase tracking-wider sm:text-xs",
              progress_classes(@configuration, @editor_step, phase)
            ]}
          >
            <span><span class="hidden sm:inline">{index}. </span>{step_label(phase)}</span>
          </li>
        </ol>

        <.card
          :if={@configuration.pending}
          class="mt-6 border-amber-400/25 bg-amber-400/[0.06]"
        >
          <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.18em] text-amber-300">
                Unconfirmed configuration
              </p>
              <h2 class="mt-2 text-xl font-semibold text-white">
                {pending_title(@configuration.pending)}
              </h2>
              <p class="mt-2 text-sm leading-6 text-zinc-300">
                The active slot file is unchanged until these settings are kept.
              </p>
              <p
                :if={@configuration.pending.remaining_seconds}
                class="mt-2 font-mono text-sm text-amber-200"
              >
                Revert in {duration(@configuration.pending.remaining_seconds)}
              </p>
              <p
                :if={is_nil(@configuration.pending.remaining_seconds)}
                class="mt-2 text-sm text-amber-200"
              >
                First-time setup has no automatic revert timer.
              </p>
            </div>
            <.badge tone={:warning}>candidate</.badge>
          </div>

          <div class="mt-5 flex flex-wrap gap-3">
            <.button
              :if={@editor_step == :confirmation and @tailnet_access}
              phx-click="keep-settings"
              phx-value-id={@configuration.pending.id}
            >
              Keep settings
            </.button>
            <.link_button
              :if={@editor_step == :confirmation and not @tailnet_access and @view.settings_url}
              href={@view.settings_url}
            >
              Reopen through Tailnet
            </.link_button>
            <p
              :if={@editor_step == :confirmation and not @tailnet_access and is_nil(@view.settings_url)}
              class="self-center text-sm text-amber-200"
            >
              Waiting for a Tailnet address before settings can be kept.
            </p>
            <.button
              phx-click="revert-configuration"
              phx-value-id={@configuration.pending.id}
              tone={:danger}
            >
              Revert now
            </.button>
          </div>
        </.card>

        <.card :if={@editor_step == :internet} class="mt-6">
          <span class="float-right text-5xl font-black text-white/[0.035]">01</span>
          <.section_header
            eyebrow="Internet"
            title="Connect to the Internet"
            description="Internet is applied and verified before Tailnet enrollment becomes available."
          />
          <form phx-submit="configure-internet" class="mt-6 grid gap-6">
            <.input
              label="Gateway display name"
              name="device[name]"
              value={editing_settings(@configuration).name}
              maxlength="80"
              required
              hint={gateway_name_hint()}
            />
            <div class="grid gap-4 border-t border-white/8 pt-6">
              <label class="grid gap-2 text-sm font-medium text-zinc-300">
                <span>Addressing</span>
                <select
                  id="configuration-internet-method"
                  name="internet[method]"
                  aria-controls="configuration-static-fields"
                  aria-expanded={to_string(network_method(editing_settings(@configuration)) == :static)}
                  data-internet-method
                  phx-hook="InternetMethod"
                  class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70"
                >
                  <option value="dhcp" selected={network_method(editing_settings(@configuration)) == :dhcp}>
                    DHCP (automatic)
                  </option>
                  <option value="static" selected={network_method(editing_settings(@configuration)) == :static}>
                    Static IPv4
                  </option>
                </select>
              </label>
              <p class="text-xs leading-5 text-zinc-500">
                DHCP obtains the IP address, subnet, gateway, and DNS settings automatically.
              </p>
              <div
                id="configuration-static-fields"
                data-static-internet-fields
                hidden={network_method(editing_settings(@configuration)) != :static}
                class="grid gap-4 sm:grid-cols-2"
              >
                <.input label="IP address" name="internet[ip_address]" value={network_value(editing_settings(@configuration), :address)} />
                <.input label="Prefix length" name="internet[prefix_length]" value={network_value(editing_settings(@configuration), :prefix_length)} />
                <.input label="Gateway" name="internet[gateway]" value={network_value(editing_settings(@configuration), :gateway)} />
                <.input label="DNS resolver" name="internet[dns]" value={network_value(editing_settings(@configuration), :dns_primary)} />
              </div>
            </div>
            <.button type="submit" class="w-full" phx-disable-with="Verifying Internet…">
              Verify Internet and continue
            </.button>
          </form>
        </.card>

        <.card :if={@editor_step == :tailnet} class="mt-6">
          <span class="float-right text-5xl font-black text-white/[0.035]">02</span>
          <.section_header
            eyebrow="Tailnet"
            title="Join the tailnet"
            description="The auth key is used once and is never written to a settings file."
          />
          <form phx-submit="configure-tailnet" class="mt-6 grid gap-5">
            <input type="hidden" name="candidate_id" value={@configuration.pending.id} />
            <.input
              label="Tailscale auth key"
              name="auth_token"
              type="password"
              autocomplete="off"
              required={!editing_settings(@configuration).tailnet_configured}
              hint={tailnet_hint(@configuration)}
            />
            <.button type="submit" class="w-full" phx-disable-with="Joining tailnet…">
              {tailnet_button_label(@configuration)}
            </.button>
          </form>
        </.card>

        <.card :if={@editor_step == :cluster} class="mt-6">
          <span class="float-right text-5xl font-black text-white/[0.035]">03</span>
          <.section_header
            eyebrow="Cluster"
            title="Choose cluster mode"
            description="Clustering is configured only after this gateway has joined its Tailnet."
          />
          <dl class="mt-6 grid grid-cols-[8rem_1fr] gap-3 rounded-xl border border-white/8 bg-zinc-950/50 p-4 text-sm">
            <dt class="text-zinc-500">Tailnet name</dt>
            <dd class="truncate text-zinc-200">{@view.tailnet.hostname || "Connected"}</dd>
            <dt class="text-zinc-500">Tailnet IP</dt>
            <dd class="font-mono text-zinc-200">{@view.tailnet.ipv4 || "Detecting…"}</dd>
          </dl>
          <form phx-submit="configure-cluster" class="mt-5 grid gap-4">
            <input type="hidden" name="candidate_id" value={@configuration.pending.id} />
            <.input
              label="Cluster group"
              name="cluster[group]"
              value={editing_settings(@configuration).cluster_group}
              list="configuration-cluster-groups"
              maxlength="128"
              pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
              hint="Select a visible group, enter a public name, or leave blank for singular mode."
            />
            <datalist id="configuration-cluster-groups">
              <option :for={group <- @view.cluster.groups} value={group.name}>
                {group.members} visible gateway(s)
              </option>
            </datalist>
            <div :if={@view.cluster.groups != []} class="rounded-xl border border-white/8 bg-zinc-950/40 p-4">
              <p class="text-xs font-bold uppercase tracking-wider text-zinc-500">Available groups</p>
              <ul class="mt-2 grid gap-2 text-sm">
                <li :for={group <- @view.cluster.groups} class="flex justify-between gap-3 text-zinc-300">
                  <span class="font-medium">{group.name}</span>
                  <span class="text-zinc-500">{group.members} visible</span>
                </li>
              </ul>
            </div>
            <.button type="submit" class="w-full" phx-disable-with="Applying cluster settings…">
              {cluster_button_label(@configuration)}
            </.button>
          </form>
        </.card>
      </div>
    </main>
    """
  end

  @impl true
  def handle_event("set-revert-timeout", %{"revert_minutes" => value}, socket) do
    case parse_revert_minutes(value) do
      {:ok, minutes} -> {:noreply, assign(socket, :revert_minutes, minutes)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("update-internet-settings", params, socket),
    do: update_settings(socket, :internet, params)

  def handle_event("update-tailnet-settings", params, socket),
    do: update_settings(socket, :tailnet, params)

  def handle_event("update-cluster-settings", params, socket),
    do: update_settings(socket, :cluster, params)

  def handle_event("configure-internet", params, socket) do
    case NervesGate.stage_internet(
           params,
           socket.assigns.connection_id,
           socket.assigns.revert_timeout
         ) do
      {:ok, _pending} ->
        {:noreply,
         socket
         |> put_flash(:info, "Internet verified. Continue with Tailnet enrollment.")
         |> refresh()
         |> assign(:editor_step, :tailnet)
         |> schedule_tick()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Internet setup failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("configure-tailnet", %{"candidate_id" => id} = params, socket) do
    case NervesGate.stage_tailnet(id, params) do
      {:ok, pending} ->
        message =
          if pending.phase == :confirmation,
            do: "Tailnet ready. Reopen through the Tailnet and keep the settings.",
            else: "Tailnet ready. Choose the cluster mode."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> refresh()
         |> assign(:editor_step, pending.phase)
         |> schedule_tick()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Tailnet setup failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("configure-cluster", %{"candidate_id" => id} = params, socket) do
    case NervesGate.stage_cluster(id, params) do
      {:ok, _pending} ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings applied. Reopen through the Tailnet and keep them.")
         |> redirect(to: ~p"/commissioning")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Cluster setup failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("keep-settings", %{"id" => id}, socket) do
    actor = %{id: socket.assigns.connection_id, tailnet?: socket.assigns.tailnet_access}

    case NervesGate.keep_settings(id, actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings kept.")
         |> redirect(to: ~p"/")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Settings were not kept: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("revert-configuration", %{"id" => id}, socket) do
    case NervesGate.revert(id) do
      :ok ->
        socket = socket |> put_flash(:info, "Temporary settings reverted.") |> refresh()
        mode = if socket.assigns.configuration.configured, do: :settings, else: :editor
        {:noreply, assign(socket, mode: mode, editor_step: :internet)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Revert failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  @impl true
  def handle_info(:configuration_tick, socket) do
    socket = socket |> assign(:tick_timer, nil) |> refresh()

    socket =
      if socket.assigns.configuration.pending do
        schedule_tick(socket)
      else
        assign(socket,
          mode: if(socket.assigns.configuration.configured, do: :settings, else: :editor),
          editor_step: :internet
        )
      end

    {:noreply, socket}
  end

  def handle_info(
        {:nerves_gate_state_changed, session, fleet},
        %{private: %{session: session}} = socket
      ) do
    previous_pending = socket.assigns.configuration.pending
    socket = refresh(socket, fleet.local)
    configuration = socket.assigns.configuration

    cond do
      socket.assigns.mode == :editor and configuration.configured and
          is_nil(configuration.pending) ->
        {:noreply, redirect(socket, to: ~p"/")}

      not is_nil(previous_pending) and is_nil(configuration.pending) ->
        {:noreply, assign(socket, :editor_step, :internet)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, reference, :process, session, _reason},
        %{private: %{session: session, session_monitor: reference}} = socket
      ) do
    {:stop, :nerves_gate_session_stopped, socket}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  defp update_settings(socket, scope, params) do
    with {:ok, minutes} <- parse_revert_minutes(params["revert_minutes"]),
         {:ok, _pending} <-
           NervesGate.update_settings(
             scope,
             Map.delete(params, "revert_minutes"),
             socket.assigns.connection_id,
             :timer.minutes(minutes)
           ) do
      {:noreply, redirect(socket, to: ~p"/commissioning")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Choose a timeout between 1 and 60 minutes.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Update failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  defp refresh(socket), do: refresh(socket, NervesGate.state(socket.private.session).local)

  defp refresh(socket, snapshot) do
    configuration =
      snapshot.state.configuration ||
        %{configured: false, current: %{}, pending: nil, last_error: nil}

    tailnet = snapshot.state.tailnet || %{ipv4: nil}
    cluster = snapshot.state.cluster || %{group: nil, groups: [], candidates: []}

    assign(socket,
      public_snapshot: snapshot,
      configuration: configuration,
      view: %{
        cluster: cluster,
        tailnet: tailnet,
        settings_url: settings_url(configuration, tailnet)
      },
      steps: @steps
    )
  end

  defp schedule_tick(socket) do
    pending = socket.assigns.configuration.pending

    if connected?(socket) && pending && pending.remaining_seconds &&
         is_nil(socket.assigns.tick_timer) do
      assign(socket, :tick_timer, Process.send_after(self(), :configuration_tick, 1_000))
    else
      socket
    end
  end

  defp current_step(%{pending: nil}), do: :internet
  defp current_step(%{pending: %{phase: phase}}), do: phase

  defp progress_classes(configuration, editor_step, phase) do
    cond do
      phase == editor_step ->
        "border-amber-300 text-amber-200"

      step_accessible?(configuration, phase) ->
        "border-emerald-400 text-emerald-300"

      true ->
        "border-white/10 text-zinc-600"
    end
  end

  defp step_accessible?(%{pending: nil}, phase), do: phase == :internet

  defp step_accessible?(%{pending: %{phase: current}}, phase) do
    current == :confirmation or step_index(phase) <= step_index(current)
  end

  defp step_index(phase), do: Enum.find_index(@steps, &(&1 == phase))

  defp step_label(:internet), do: "Internet"
  defp step_label(:tailnet), do: "Tailnet"
  defp step_label(:cluster), do: "Cluster"

  defp pending_title(%{phase: :tailnet}), do: "Internet verified"
  defp pending_title(%{phase: :cluster}), do: "Tailnet ready"
  defp pending_title(%{phase: :confirmation}), do: "Ready to keep"

  defp change_description(_configuration),
    do: "Configure Internet, Tailnet, and clustering in order."

  defp tailnet_button_label(_configuration), do: "Join Tailnet and continue"
  defp cluster_button_label(_configuration), do: "Apply complete candidate"

  defp tailnet_hint(configuration) do
    if editing_settings(configuration).tailnet_configured,
      do: "Leave blank to keep the current Tailnet profile.",
      else: "Required for initial configuration. Use a key scoped for this gateway."
  end

  defp editing_settings(%{pending: %{candidate: candidate}}), do: candidate
  defp editing_settings(configuration), do: configuration.current

  defp network_method(settings) do
    case settings.internet do
      %{method: method} -> method
      _missing -> :dhcp
    end
  end

  defp network_value(settings, key) do
    case settings.internet do
      internet when is_map(internet) -> Map.get(internet, key)
      _missing -> nil
    end
  end

  defp assign_private(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, socket ->
      put_in(socket.private[key], value)
    end)
  end

  defp settings_url(%{pending: %{phase: :confirmation}}, %{ipv4: ipv4})
       when is_binary(ipv4),
       do: "http://#{ipv4}/commissioning"

  defp settings_url(_configuration, _tailnet), do: nil

  defp settings_scope_label(:internet), do: "Internet"
  defp settings_scope_label(:tailnet), do: "Tailnet"
  defp settings_scope_label(:cluster), do: "Cluster"

  attr(:scope, :atom, required: true, values: [:internet, :tailnet])
  attr(:timeout, :integer, required: true)

  defp connection_pause_notice(assigns) do
    ~H"""
    <div
      data-connection-pause={@scope}
      class="rounded-xl border border-amber-400/20 bg-amber-400/[0.06] px-4 py-3"
    >
      <p class="text-sm font-semibold text-amber-200">The connection may pause</p>
      <p class="mt-1 text-xs leading-5 text-zinc-400">
        {connection_pause_message(@scope)} If the update cannot be kept, the gateway restores the
        accepted settings after {minutes_label(@timeout)}.
      </p>
      <div
        role="status"
        aria-live="polite"
        class="mt-3 hidden items-center gap-2 text-xs font-bold text-amber-200 phx-submit-loading:flex"
      >
        <span class="size-2 animate-pulse rounded-full bg-amber-300"></span>
        Applying → reconnecting → waiting for Keep changes or Revert changes
      </div>
    </div>
    """
  end

  defp connection_pause_message(:internet),
    do: "Changing the uplink can interrupt this browser while addresses and routes settle."

  defp connection_pause_message(:tailnet),
    do: "Changing the Tailnet profile can interrupt this browser until the new address appears."

  defp connection_critical_scope?(scope), do: scope in [:internet, :tailnet]

  defp gateway_name_hint do
    "Friendly label shown in NervesGate dashboards and gateway lists. " <>
      "It does not change the device ID, setup Wi-Fi name, Tailnet hostname, or Erlang node name."
  end

  defp minutes_label(1), do: "1 minute"
  defp minutes_label(minutes), do: "#{minutes} minutes"

  defp parse_revert_minutes(value) do
    case Integer.parse(to_string(value)) do
      {minutes, ""} when minutes in 1..@maximum_revert_minutes -> {:ok, minutes}
      _invalid -> :error
    end
  end

  defp duration(seconds), do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp connection_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

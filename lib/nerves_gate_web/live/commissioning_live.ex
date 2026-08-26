defmodule NervesGateWeb.CommissioningLive do
  @moduledoc "Commissions a gateway or applies one guarded settings change."

  use NervesGateWeb, :live_view

  import NervesGateWeb.GatewayComponents

  alias NervesGateWeb.FormHelpers

  @steps [:internet, :tailnet, :cluster]
  @default_revert_minutes 1
  @maximum_revert_minutes 60

  @impl true
  def mount(params, session, socket) do
    connection_id = connection_id()
    tailnet_access = Map.get(session, "tailnet_access", false)
    loopback_access = loopback_access?(session)

    case maybe_accept(params, connection_id, tailnet_access) do
      :accepted ->
        {:ok, socket |> put_flash(:info, "Settings accepted.") |> redirect(to: ~p"/")}

      {:continue, flash} ->
        mount_editor(socket, connection_id, loopback_access, flash)
    end
  end

  defp mount_editor(socket, connection_id, loopback_access, flash) do
    {:ok, session, fleet} = NervesGate.connect()
    snapshot = fleet.local
    status = snapshot.state.configuration
    mode = if status.configured and is_nil(status.pending), do: :entry, else: :editor

    socket =
      socket
      |> assign(
        connection_id: connection_id,
        loopback_access: loopback_access,
        mode: mode,
        editor_step: current_step(status),
        tick_timer: nil,
        public_snapshot: snapshot,
        change_scope: :tailnet,
        revert_minutes: @default_revert_minutes,
        revert_timeout:
          if(status.configured, do: :timer.minutes(@default_revert_minutes), else: nil)
      )
      |> assign_private(
        session: session,
        session_monitor: Process.monitor(session)
      )
      |> maybe_put_accept_error(flash)
      |> refresh(snapshot)
      |> schedule_tick()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen">
      <div :if={@mode == :entry} class="mx-auto w-full max-w-xl px-4 py-8 sm:px-6 sm:py-14">
        <header class="border-b border-white/10 pb-6">
          <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">Change settings</h1>
          <p class="mt-2 text-sm leading-6 text-zinc-400">
            Choose one area to change. It is applied temporarily and restored automatically
            unless accepted from a fresh connection.
          </p>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <.card class="mt-6">
          <form phx-submit="change-settings" class="grid gap-5">
            <label class="grid gap-2 text-sm font-medium text-zinc-300">
              <span>Settings to change</span>
              <select
                name="configuration[scope]"
                class="min-h-11 rounded-xl border border-white/10 bg-zinc-950/80 px-3.5 text-zinc-100 outline-none focus:border-emerald-400/70"
              >
                <option value="tailnet" selected={@change_scope == :tailnet}>Tailnet only</option>
                <option value="cluster" selected={@change_scope == :cluster}>Cluster only</option>
                <option value="complete" selected={@change_scope == :complete}>All settings</option>
              </select>
            </label>
            <.input
              label="Auto-revert after"
              name="configuration[revert_minutes]"
              type="number"
              value={@revert_minutes}
              min="1"
              max="60"
              step="1"
              required
              hint="Minutes. Defaults to 1; the maximum is 60."
            />
            <.button type="submit" class="w-full">Start change</.button>
          </form>
        </.card>

        <div class="mt-5 text-center">
          <.link href={~p"/"} class="text-sm text-zinc-400 hover:text-white">Back to status</.link>
        </div>
      </div>

      <div :if={@mode == :editor} class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <header class="flex flex-col gap-4 border-b border-white/10 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">
              {if @configuration.configured, do: "Change settings", else: "Configure gateway"}
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
              {change_description(@configuration)}
            </p>
          </div>
          <.link_button :if={@configuration.configured} href={~p"/"} class="shrink-0">
            Back to status
          </.link_button>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <ol
          :if={complete_flow?(@configuration)}
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
            <button
              type="button"
              phx-click="edit-step"
              phx-value-step={phase}
              disabled={!step_accessible?(@configuration, phase)}
              class="w-full disabled:cursor-not-allowed"
            >
              <span class="hidden sm:inline">{index}. </span>{step_label(phase)}
            </button>
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
                The active slot file is unchanged until this change is accepted.
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
            <.link_button
              :if={@editor_step == :confirmation and @view.acceptance_url}
              href={@view.acceptance_url}
            >
              Accept settings
            </.link_button>
            <p
              :if={@editor_step == :confirmation and is_nil(@view.acceptance_url)}
              class="self-center text-sm text-amber-200"
            >
              Waiting for a Tailnet address before acceptance.
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
              label="Gateway name"
              name="device[name]"
              value={editing_settings(@configuration).name}
              maxlength="80"
              required
              hint="Public display name replicated to connected gateways."
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
  def handle_event("change-settings", %{"configuration" => params}, socket) do
    with {:ok, minutes} <- parse_revert_minutes(params["revert_minutes"]),
         {:ok, scope} <- parse_change_scope(params["scope"]) do
      start_change(socket, scope, minutes)
    else
      :error ->
        {:noreply,
         put_flash(socket, :error, "Choose settings and a time between 1 and 60 minutes.")}
    end
  end

  def handle_event("edit-step", %{"step" => step}, socket) do
    phase =
      Map.get(%{"internet" => :internet, "tailnet" => :tailnet, "cluster" => :cluster}, step)

    if phase && step_accessible?(socket.assigns.configuration, phase) do
      {:noreply, assign(socket, :editor_step, phase)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("configure-internet", params, socket) do
    result =
      case socket.assigns.configuration.pending do
        nil ->
          NervesGate.stage_internet(
            params,
            socket.assigns.connection_id,
            socket.assigns.revert_timeout
          )

        pending ->
          NervesGate.update_internet(pending.id, params)
      end

    case result do
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
            do: "Tailnet change applied. Accept it through the Tailnet to finish.",
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
         |> put_flash(:info, "Candidate applied. Accept it through the Tailnet to finish.")
         |> refresh()
         |> assign(:editor_step, :confirmation)
         |> schedule_tick()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Cluster setup failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("revert-configuration", %{"id" => id}, socket) do
    case NervesGate.revert(id) do
      :ok ->
        socket = socket |> put_flash(:info, "Candidate reverted.") |> refresh()
        mode = if socket.assigns.configuration.configured, do: :entry, else: :editor
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
          mode: if(socket.assigns.configuration.configured, do: :entry, else: :editor),
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

  defp start_change(socket, :complete, minutes) do
    {:noreply,
     assign(socket,
       mode: :editor,
       editor_step: :internet,
       change_scope: :complete,
       revert_minutes: minutes,
       revert_timeout: :timer.minutes(minutes)
     )}
  end

  defp start_change(socket, scope, minutes) when scope in [:tailnet, :cluster] do
    timeout = :timer.minutes(minutes)

    case NervesGate.begin_change(scope, socket.assigns.connection_id, timeout) do
      {:ok, pending} ->
        {:noreply,
         socket
         |> assign(
           mode: :editor,
           editor_step: pending.phase,
           change_scope: scope,
           revert_minutes: minutes,
           revert_timeout: timeout
         )
         |> refresh()
         |> schedule_tick()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not start change: #{FormHelpers.format_error(reason)}")}
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
        acceptance_url: acceptance_url(configuration, tailnet, socket.assigns.loopback_access)
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

  defp pending_title(%{scope: :tailnet, phase: :tailnet}), do: "Ready to change Tailnet"
  defp pending_title(%{scope: :cluster, phase: :cluster}), do: "Ready to change Cluster"
  defp pending_title(%{phase: :tailnet}), do: "Internet verified"
  defp pending_title(%{phase: :cluster}), do: "Tailnet ready"
  defp pending_title(%{phase: :confirmation}), do: "Ready to accept"

  defp complete_flow?(%{configured: false}), do: true
  defp complete_flow?(%{pending: %{scope: scope}}), do: scope == :complete
  defp complete_flow?(_configuration), do: false

  defp change_description(%{configured: false}),
    do: "Configure Internet, Tailnet, and clustering in order."

  defp change_description(%{pending: %{scope: :tailnet}}),
    do: "Change only the Tailnet profile. Internet and cluster settings stay unchanged."

  defp change_description(%{pending: %{scope: :cluster}}),
    do: "Change only the cluster group. Internet and Tailnet settings stay unchanged."

  defp change_description(_configuration),
    do: "Configure Internet, Tailnet, and clustering in order."

  defp tailnet_button_label(%{pending: %{scope: :tailnet}}), do: "Apply Tailnet change"
  defp tailnet_button_label(_configuration), do: "Join Tailnet and continue"

  defp cluster_button_label(%{pending: %{scope: :cluster}}), do: "Apply Cluster change"
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

  defp maybe_accept(%{"accept" => id}, connection_id, tailnet_access)
       when is_binary(id) do
    case NervesGate.confirm(id, %{id: connection_id, tailnet?: tailnet_access}) do
      :ok -> :accepted
      {:error, reason} -> {:continue, "Accept failed: #{FormHelpers.format_error(reason)}"}
    end
  end

  defp maybe_accept(_params, _connection_id, _tailnet_access), do: {:continue, nil}

  defp assign_private(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, socket ->
      put_in(socket.private[key], value)
    end)
  end

  defp maybe_put_accept_error(socket, nil), do: socket
  defp maybe_put_accept_error(socket, message), do: put_flash(socket, :error, message)

  defp acceptance_url(%{pending: %{id: id, phase: :confirmation}}, _tailnet, true) do
    "/commissioning?#{URI.encode_query(%{"accept" => id})}"
  end

  defp acceptance_url(
         %{pending: %{id: id, phase: :confirmation}},
         %{ipv4: ipv4},
         false
       )
       when is_binary(ipv4) do
    "http://#{ipv4}/commissioning?#{URI.encode_query(%{"accept" => id})}"
  end

  defp acceptance_url(_configuration, _tailnet, _loopback_access), do: nil

  defp loopback_access?(%{"remote_ip" => "127." <> _rest}), do: true
  defp loopback_access?(%{"remote_ip" => "::1"}), do: true
  defp loopback_access?(_session), do: false

  defp parse_change_scope("tailnet"), do: {:ok, :tailnet}
  defp parse_change_scope("cluster"), do: {:ok, :cluster}
  defp parse_change_scope("complete"), do: {:ok, :complete}
  defp parse_change_scope(_scope), do: :error

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

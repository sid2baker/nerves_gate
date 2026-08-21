defmodule NervesGateWeb.StatusLive do
  @moduledoc false
  use NervesGateWeb, :live_view

  alias NervesGate.Device
  alias NervesGate.Setup
  alias NervesGate.Status
  alias NervesGate.Tailscale.Observer

  @topics ~w(setup device network network_health tailscale beam alarms)

  @impl true
  def mount(_params, session, socket) do
    remote_ip = Map.get(session, "remote_ip", "unknown")
    tailnet_access = Map.get(session, "tailnet_access", false)
    actor = Observer.actor_for_ip(remote_ip)
    status = Status.snapshot()

    if connected?(socket) do
      Enum.each(@topics, &Phoenix.PubSub.subscribe(NervesGate.PubSub, &1))

      if tailnet_access and status.setup.ready do
        Phoenix.PubSub.subscribe(NervesGate.PubSub, NervesGateWeb.Presence.topic())
        NervesGateWeb.Presence.track_visitor(self(), actor)
      end
    end

    {:ok, assign(socket, status: status, actor: actor, tailnet_access: tailnet_access)}
  end

  @impl true
  def handle_event("configure-internet", %{"internet" => params}, socket) do
    case Setup.configure_internet(params) do
      {:ok, _phase} -> setup_ok(socket, "Internet verified and saved.")
      {:error, reason} -> setup_error(socket, "Internet setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-tailscale", %{"auth_token" => token}, socket) do
    case Setup.configure_tailscale(token) do
      {:ok, :cluster} -> setup_ok(socket, "Tailscale connected.")
      {:error, reason} -> setup_error(socket, "Tailscale setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-cluster", _params, socket) do
    case Setup.configure_cluster() do
      {:ok, :ready} -> setup_ok(socket, "Gateway is ready.")
      {:error, reason} -> setup_error(socket, "Cluster setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("rename-device", %{"device" => %{"name" => name}}, socket) do
    case Device.rename(name, socket.assigns.actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Device name saved.")
         |> assign(status: Status.snapshot())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Name must contain 1–80 printable characters.")}
    end
  end

  def handle_event("enable-recovery", _params, socket) do
    :ok = NervesGate.Recovery.activate()
    {:noreply, put_flash(socket, :info, "Local recovery access is being enabled.")}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, assign(socket, status: Status.snapshot())}

  @impl true
  def render(assigns) do
    ~H"""
    <NervesGateWeb.SetupPage.current
      :if={!@status.setup.ready or !@tailnet_access}
      status={@status}
      flash={@flash}
    />
    <.dashboard :if={@status.setup.ready and @tailnet_access} {assigns} />
    """
  end

  def dashboard(assigns) do
    ~H"""
    <main class="dashboard">
      <header class="topbar">
        <details class="node-menu">
          <summary aria-label="Open cluster nodes"><span class="hamburger">☰</span></summary>
          <nav>
            <div class="menu-title">Cluster nodes</div>
            <a :for={node <- @status.cluster.nodes} href={node_url(node)} class={if node.self, do: "current"}>
              <span class={if node.online, do: "node-dot online", else: "node-dot"}></span>
              <span><strong>{node.hostname}</strong><small>{node.ipv4}</small></span>
            </a>
            <p :if={@status.cluster.nodes == []}>No tailnet nodes discovered.</p>
          </nav>
        </details>

        <div class="brand">
          <span class="eyebrow">NervesGate</span>
          <h1>{@status.device["name"]}</h1>
        </div>

        <div class="tailnet-summary">
          <div><strong>{@status.tailnet.hostname || "offline"}</strong><small>{@status.tailnet.ipv4 || "No tailnet IP"}</small></div>
          <div class="people" title="People viewing one or more gateway dashboards">
            <span>♙</span><strong>{@status.people_count}</strong>
          </div>
        </div>
      </header>

      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash bad">{Phoenix.Flash.get(@flash, :error)}</p>

      <section class="hero">
        <div>
          <span class={status_class(@status.setup.ready)}>{if @status.setup.ready, do: "Operational", else: "Setup required"}</span>
          <h2>Gateway overview</h2>
          <p>Live state from this device and its Tailscale-backed Erlang cluster.</p>
        </div>
      </section>

      <section class="metric-row">
        <.metric label="Tailnet" value={online_label(@status.tailnet.online)} good={@status.tailnet.online} />
        <.metric label="Cluster peers" value={length(@status.cluster.connected)} good={@status.cluster.running} />
        <.metric label="People connected" value={@status.people_count} good={@status.people_count > 0} neutral />
        <.metric label="Active alarms" value={length(@status.alarms)} good={@status.alarms == []} />
      </section>

      <section class="content-grid">
        <article class="card span-two">
          <div class="card-heading"><div><span class="eyebrow">Identity</span><h2>Device information</h2></div></div>
          <form class="inline-form" phx-submit="rename-device">
            <label>Display name
              <input name="device[name]" value={@status.device["name"]} maxlength="80" required />
            </label>
            <button type="submit">Save name</button>
          </form>
          <dl class="details">
            <dt>Machine ID</dt><dd>{@status.identity.machine_id}</dd>
            <dt>System hostname</dt><dd>{@status.identity.hostname}</dd>
            <dt>Last changed</dt><dd>{@status.device["updated_at"] || "Never"}</dd>
            <dt>Changed by</dt><dd>{changed_by(@status.device["updated_by"])}</dd>
          </dl>
          <p class="hint">Stored as readable JSON in <code>/data/device.json</code>. The schema already reserves versioned documents and change history.</p>
        </article>

        <article class="card">
          <span class="eyebrow">Initialization</span><h2>Setup</h2>
          <dl class="details compact">
            <dt>Phase</dt><dd>{@status.setup.phase}</dd>
            <dt>Ready</dt><dd class={text_class(@status.setup.ready)}>{@status.setup.ready}</dd>
            <dt>Recovery</dt><dd>{@status.setup.recovery}</dd>
          </dl>
        </article>

        <article class="card">
          <span class="eyebrow">Connectivity</span><h2>Internet</h2>
          <ul class="checks">
            <.check_row label="Physical link" value={check(@status, :physical_link)} />
            <.check_row label="IP address" value={check(@status, :ip_address)} />
            <.check_row label="Default route" value={check(@status, :default_route)} />
            <.check_row label="DNS" value={check(@status, :dns)} />
            <.check_row label="HTTPS" value={check(@status, :internet_https)} />
          </ul>
        </article>

        <article class="card span-two">
          <span class="eyebrow">Tailnet</span><h2>Cluster nodes</h2>
          <table>
            <thead><tr><th>Node</th><th>Tailnet IP</th><th>Status</th><th></th></tr></thead>
            <tbody>
              <tr :for={node <- @status.cluster.nodes}>
                <td>{node.hostname}</td><td><code>{node.ipv4}</code></td>
                <td><span class={if node.online, do: "state good", else: "state bad"}>{if node.online, do: "online", else: "offline"}</span></td>
                <td><a href={node_url(node)}>Open →</a></td>
              </tr>
              <tr :if={@status.cluster.nodes == []}><td colspan="4">No nodes discovered.</td></tr>
            </tbody>
          </table>
        </article>

        <article class="card">
          <span class="eyebrow">Runtime</span><h2>System</h2>
          <dl class="details compact">
            <dt>Firmware</dt><dd>{@status.diagnostics.firmware_version}</dd>
            <dt>Target</dt><dd>{@status.diagnostics.target}</dd>
            <dt>OTP</dt><dd>{@status.diagnostics.otp_release}</dd>
            <dt>Uptime</dt><dd>{duration(@status.diagnostics.uptime_seconds)}</dd>
            <dt>Memory</dt><dd>{megabytes(@status.diagnostics.memory_bytes)} MB</dd>
          </dl>
        </article>

        <article class="card span-two">
          <span class="eyebrow">Operations</span><h2>Active alarms</h2>
          <p :if={@status.alarms == []} class="empty-state">Everything looks healthy.</p>
          <ul :if={@status.alarms != []} class="alarm-list">
            <li :for={alarm <- @status.alarms}><strong>{alarm.id}</strong><span>{alarm.description}</span></li>
          </ul>
        </article>

        <article class="card danger-zone">
          <span class="eyebrow">Local access</span><h2>Recovery</h2>
          <p>Re-enable the isolated setup network without changing saved Internet or Tailscale state.</p>
          <button type="button" class="danger" phx-click="enable-recovery">Enable recovery</button>
        </article>
      </section>
    </main>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:good, :boolean, required: true)
  attr(:neutral, :boolean, default: false)

  defp metric(assigns) do
    ~H"""
    <article class="metric"><span>{@label}</span><strong class={if @neutral, do: "", else: text_class(@good)}>{@value}</strong></article>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp check_row(assigns) do
    ~H"""
    <li><span>{@label}</span><strong class={check_class(@value)}>{@value}</strong></li>
    """
  end

  defp check(status, key) do
    status.network.connectivity
    |> Map.get(:checks, %{})
    |> Map.get(key, :unknown)
    |> case do
      :ok -> "ok"
      :unknown -> "unknown"
      {:error, reason} -> reason |> to_string() |> String.replace("_", " ")
      other -> to_string(other)
    end
  end

  defp setup_ok(socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> assign(status: Status.snapshot())}
  end

  defp setup_error(socket, message), do: {:noreply, put_flash(socket, :error, message)}

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason) when is_map(reason) do
    Enum.map_join(reason, ", ", fn {field, message} -> "#{field} #{message}" end)
  end

  defp format_error(_reason), do: "operation failed"

  defp node_url(%{ipv4: ip}), do: "http://#{ip}/"
  defp changed_by(nil), do: "Never"
  defp changed_by(%{"name" => name, "ip" => ip}), do: "#{name} · #{ip}"
  defp changed_by(_actor), do: "Unknown"
  defp online_label(true), do: "Online"
  defp online_label(false), do: "Offline"
  defp status_class(true), do: "state good"
  defp status_class(false), do: "state bad"
  defp text_class(true), do: "good-text"
  defp text_class(false), do: "bad-text"
  defp check_class("ok"), do: "good-text"
  defp check_class("unknown"), do: "muted"
  defp check_class(_value), do: "bad-text"
  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  defp megabytes(bytes), do: Float.round(bytes / 1_048_576, 1)
end

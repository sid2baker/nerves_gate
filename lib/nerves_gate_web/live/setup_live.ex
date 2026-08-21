defmodule NervesGateWeb.SetupLive do
  @moduledoc false
  use NervesGateWeb, :live_view

  alias NervesGate.Setup
  alias NervesGate.Status

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "setup")
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")
    end

    {:ok, assign(socket, status: Status.snapshot())}
  end

  @impl true
  def handle_event("configure-internet", %{"internet" => params}, socket) do
    case Setup.configure_internet(params) do
      {:ok, _phase} -> ok(socket, "Internet verified and saved.")
      {:error, reason} -> error(socket, "Internet setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-tailscale", %{"auth_token" => token}, socket) do
    case Setup.configure_tailscale(token) do
      {:ok, :cluster} -> ok(socket, "Tailscale enrolled. Waiting for its tailnet address.")
      {:error, reason} -> error(socket, "Tailscale setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-cluster", _params, socket) do
    case Setup.configure_cluster() do
      {:ok, :ready} -> ok(socket, "Gateway is ready.")
      {:error, reason} -> error(socket, "Cluster setup failed: #{format_error(reason)}")
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, assign(socket, status: Status.snapshot())}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="setup-shell">
      <header class="setup-header">
        <div>
          <span class="eyebrow">NervesGate</span>
          <h1>Initialize this gateway</h1>
          <p>Three explicit steps. Each completed step is saved under <code>/data</code>.</p>
        </div>
        <span class="phase-pill">{phase_label(@status.setup.phase)}</span>
      </header>

      <.flash_group flash={@flash} />

      <ol class="steps" aria-label="Initialization progress">
        <li :for={{phase, index} <- Enum.with_index(phases(), 1)} class={step_class(@status.setup.phase, phase)}>
          <span>{index}</span>{phase_label(phase)}
        </li>
      </ol>

      <section class="setup-grid">
        <article class="card setup-card">
          <span class="step-number">01</span>
          <h2>Internet</h2>
          <p>DHCP is the default. Static settings are verified before they replace the working configuration.</p>
          <form phx-submit="configure-internet">
            <label>Addressing
              <select name="internet[method]">
                <option value="dhcp">DHCP</option>
                <option value="static">Static IPv4</option>
              </select>
            </label>
            <label>IP address <input name="internet[ip_address]" placeholder="192.0.2.20" /></label>
            <label>Prefix <input name="internet[prefix_length]" placeholder="24" /></label>
            <label>Gateway <input name="internet[gateway]" placeholder="192.0.2.1" /></label>
            <label>DNS <input name="internet[dns]" placeholder="1.1.1.1" /></label>
            <button type="submit">Verify Internet</button>
          </form>
          <code class="endpoint">POST /configure/internet</code>
        </article>

        <article class="card setup-card">
          <span class="step-number">02</span>
          <h2>Tailscale</h2>
          <p>The auth token is used once, filtered from request logs, and never written to disk.</p>
          <form phx-submit="configure-tailscale">
            <label>Auth token
              <input type="password" name="auth_token" autocomplete="off" required />
            </label>
            <button type="submit" disabled={@status.setup.phase == :internet}>Join tailnet</button>
          </form>
          <code class="endpoint">POST /configure/tailscale</code>
        </article>

        <article class="card setup-card">
          <span class="step-number">03</span>
          <h2>Cluster</h2>
          <p>Starts Erlang distribution and peer discovery on the assigned Tailscale address.</p>
          <dl>
            <dt>Tailnet name</dt><dd>{@status.tailnet.hostname || "Waiting…"}</dd>
            <dt>Tailnet IP</dt><dd>{@status.tailnet.ipv4 || "Waiting…"}</dd>
          </dl>
          <button type="button" phx-click="configure-cluster" disabled={@status.setup.phase not in [:cluster, :ready]}>
            Start cluster
          </button>
          <code class="endpoint">POST /configure/cluster</code>
        </article>
      </section>

      <section :if={@status.setup.ready} class="ready-banner">
        <div><strong>Ready.</strong> Local setup access is now disabled.</div>
        <a href={dashboard_url(@status.tailnet.ipv4)}>Open tailnet dashboard →</a>
      </section>
    </main>
    """
  end

  defp ok(socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> assign(status: Status.snapshot())}
  end

  defp error(socket, message), do: {:noreply, put_flash(socket, :error, message)}

  defp phases, do: [:internet, :tailscale, :cluster, :ready]

  defp step_class(current, phase) do
    current_index = Enum.find_index(phases(), &(&1 == current)) || -1
    phase_index = Enum.find_index(phases(), &(&1 == phase))
    if phase_index <= current_index, do: "complete", else: ""
  end

  defp phase_label(phase), do: phase |> to_string() |> String.capitalize()
  defp dashboard_url(nil), do: "#"
  defp dashboard_url(ip), do: "http://#{ip}/"

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason) when is_map(reason) do
    Enum.map_join(reason, ", ", fn {field, message} -> "#{field} #{message}" end)
  end

  defp format_error(_reason), do: "operation failed"

  attr(:flash, :map, required: true)

  defp flash_group(assigns) do
    ~H"""
    <p :if={Phoenix.Flash.get(@flash, :info)} class="flash">{Phoenix.Flash.get(@flash, :info)}</p>
    <p :if={Phoenix.Flash.get(@flash, :error)} class="flash bad">{Phoenix.Flash.get(@flash, :error)}</p>
    """
  end
end

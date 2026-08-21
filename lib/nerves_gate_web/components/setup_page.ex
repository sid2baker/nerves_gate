defmodule NervesGateWeb.SetupPage do
  @moduledoc false
  use NervesGateWeb, :html

  attr(:status, :map, required: true)
  attr(:flash, :map, required: true)

  def current(assigns) do
    ~H"""
    <main class="setup-shell">
      <header class="setup-header">
        <div>
          <span class="eyebrow">NervesGate</span>
          <h1>Initialize this gateway</h1>
          <p>Complete the current step. Successful steps are saved under <code>/data</code>.</p>
        </div>
        <span class="phase-pill">{phase_label(@status.setup.phase)}</span>
      </header>

      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash bad">{Phoenix.Flash.get(@flash, :error)}</p>

      <ol class="steps" aria-label="Initialization progress">
        <li :for={{phase, index} <- Enum.with_index(phases(), 1)} class={step_class(@status.setup.phase, phase)}>
          <span>{index}</span>{phase_label(phase)}
        </li>
      </ol>

      <section class="current-step">
        <article :if={@status.setup.phase in [:internet, :recovery]} class="card setup-card">
          <span class="step-number">01</span>
          <span class="eyebrow">Current step</span>
          <h2>Connect to the Internet</h2>
          <p>DHCP is the default. Static settings replace the working configuration only after verification.</p>
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
          <code class="endpoint">POST /api/setup/internet</code>
        </article>

        <article :if={@status.setup.phase == :tailscale} class="card setup-card">
          <span class="step-number">02</span>
          <span class="eyebrow">Current step</span>
          <h2>Join the tailnet</h2>
          <p>The auth key is used for this request and is never written to disk.</p>
          <form phx-submit="configure-tailscale">
            <label>Auth key
              <input type="password" name="auth_token" autocomplete="off" required />
            </label>
            <button type="submit">Join tailnet</button>
          </form>
          <code class="endpoint">POST /api/setup/tailscale</code>
        </article>

        <article :if={@status.setup.phase == :cluster} class="card setup-card">
          <span class="step-number">03</span>
          <span class="eyebrow">Current step</span>
          <h2>Start the cluster</h2>
          <p>Tailscale is connected. Start Erlang distribution and discover the other NervesGate nodes.</p>
          <dl>
            <dt>Tailnet name</dt><dd>{@status.tailnet.hostname || "Connected"}</dd>
            <dt>Tailnet IP</dt><dd>{@status.tailnet.ipv4 || "Detecting…"}</dd>
          </dl>
          <button type="button" phx-click="configure-cluster">Start cluster</button>
          <code class="endpoint">POST /api/setup/cluster</code>
        </article>

        <article :if={@status.setup.phase == :ready} class="card setup-card finished-step">
          <span class="step-number">✓</span>
          <span class="eyebrow">Finished</span>
          <h2>Gateway ready</h2>
          <p>Initialization is complete. Management is now available only through Tailscale.</p>
          <a class="button-link" href={dashboard_url(@status.tailnet.ipv4)}>Open dashboard</a>
        </article>
      </section>
    </main>
    """
  end

  defp phases, do: [:internet, :tailscale, :cluster, :ready]

  defp step_class(current, phase) do
    current_index = Enum.find_index(phases(), &(&1 == current)) || 0
    phase_index = Enum.find_index(phases(), &(&1 == phase))
    if phase_index <= current_index, do: "complete", else: ""
  end

  defp phase_label(:recovery), do: "Internet recovery"
  defp phase_label(phase), do: phase |> to_string() |> String.capitalize()
  defp dashboard_url(nil), do: "#"
  defp dashboard_url(ip), do: "http://#{ip}/"
end

defmodule NervesGateWeb.NetworkStatus do
  use Phoenix.Component

  attr(:status, :map, required: true)

  def topology(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm" aria-label="Network topology">
      <div class="card-body">
        <h2 class="card-title">Your connections</h2>
        <p :if={@status.observed && @status.observed.simulated} class="alert alert-info">
          Host simulation — the computer's network is not changed.
        </p>
        <div :if={@status.observed} class="grid gap-4 md:grid-cols-3 items-center">
          <div class="space-y-3">
            <div :for={port <- @status.observed.ports} class="border border-base-300 rounded-box p-4">
              <strong>{port.name}</strong>
              <span class={
                if port.link, do: "badge badge-success ml-2", else: "badge badge-ghost ml-2"
              }>
                {cond do
                  not port.present -> "Not installed"
                  port.link -> "Cable connected"
                  true -> "No cable"
                end}
              </span>
              <p class="text-sm">
                {if port.master == "br0", do: "Part of your local network", else: "Waiting for bridge"}
              </p>
            </div>
          </div>
          <div class="border-2 border-primary rounded-box p-4 text-center">
            <strong>Nerves Gate</strong>
            <p>One shared Ethernet network</p>
            <p :for={ip <- @status.observed.bridge.addresses} class="font-mono text-sm">
              {ip.address}/{ip.prefix_length}
            </p>
            <p :if={@status.observed.bridge.addresses == []}>Waiting for a local IP address</p>
            <details class="mt-2 text-sm">
              <summary>Bridge details</summary>
              <p>br0 · {@status.observed.bridge.state || "not available"}</p>
            </details>
          </div>
          <div class="space-y-3 text-sm">
            <div class="border border-base-300 rounded-box p-4">
              <strong>4G</strong><p>Not integrated yet. Setup works without a modem.</p>
            </div>
            <div class="border border-base-300 rounded-box p-4">
              <strong>Remote access</strong><p>Tailscale integration is not enabled yet.</p>
            </div>
          </div>
        </div>
        <p :if={!@status.observed} class="alert alert-warning">Connection status is unavailable.</p>
        <p :if={@status.recovering} class="alert alert-error">
          Restoring saved Ethernet settings. New changes are paused; keep your recovery connection available.
        </p>
        <details :if={@status.error} class="text-sm">
          <summary>Diagnostics</summary><pre class="whitespace-pre-wrap">{inspect(@status.error)}</pre>
        </details>
      </div>
    </section>
    """
  end
end

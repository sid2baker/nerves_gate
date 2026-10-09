defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold">Your local network</h1>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title">A simple way to reach your equipment</h2>
        <p>Connect either Ethernet port to your existing network. No internet is needed for setup.</p>
        <p>Firmware {NervesGate.version()} · {NervesGate.target()}</p>
        <a href="/setup" class="btn btn-primary w-fit">Open guided setup</a>
      </div>
    </section>
    """
  end
end

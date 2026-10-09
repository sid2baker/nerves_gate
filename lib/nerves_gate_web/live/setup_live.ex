defmodule NervesGateWeb.SetupLive do
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold">Welcome to Nerves Gate</h1>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <p>Setup runs entirely on this gateway. You do not need internet or a SIM card.</p>
        <p>The networking foundation is being prepared. No settings have been changed.</p>
        <a href="/" class="btn btn-outline w-fit">Back to dashboard</a>
      </div>
    </section>
    """
  end
end

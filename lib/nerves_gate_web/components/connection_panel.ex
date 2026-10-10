defmodule NervesGateWeb.ConnectionPanel do
  @moduledoc "Self-updating connection panels, using LiveView's managed component subscriptions."
  use Phoenix.LiveComponent
  alias NervesGate.Device
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus

  @impl true
  def mount(socket) do
    Phoenix.LiveView.subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)
    {:ok, assign(socket, projection: Device.projection())}
  end

  @impl true
  def update(assigns, socket) do
    # Presentation options only. Live observations belong to this component;
    # a parent's unsent form draft must never become observed connection state.
    {:ok, socket |> assign(assigns) |> assign(:projection, Device.projection())}
  end

  @doc false
  def handle_device({:device, _snapshot}, socket) do
    # A queued notification can predate a command reply. Query, don't rewind.
    assign(socket, projection: Device.projection())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.topology :if={@kind == :ports} projection={@projection} />
      <.panel :if={@kind == :internet} title="Internet connection" icon="internet">
        <.internet_progress projection={@projection} />
        <:footer>
          <a href="/internet" class="ui-text-link">Internet &amp; backup <.icon name="arrow" /></a>
        </:footer>
      </.panel>
    </div>
    """
  end
end

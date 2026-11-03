defmodule NervesGate.Application do
  @moduledoc false
  use Application

  # Device targets only. Host builds compile this code for checks and the
  # workbench but never start it.
  @impl true
  def start(_type, _args) do
    :logger.add_primary_filter(
      :cellular_credentials,
      {&NervesGate.Cellular.filter_log/2, nil}
    )

    NervesGate.Distribution.configure_cookie()

    # rest_for_one: an earlier child's failure restarts every later child.
    children = [
      {Phoenix.PubSub, name: NervesGate.PubSub},
      NervesGate.Plugins.UI,
      # One-time routing setup before Network.
      NervesGate.Network.Vintage,
      {PropertyTable, name: NervesGate.Properties},
      # Small device-local values with no better owner, such as the SIM PIN.
      {PropertyTable, name: NervesGate.Settings, persist_data_path: "/data/nerves_gate/settings"},
      NervesGate.SSH,
      NervesGate.Network,
      NervesGate.Remote,
      NervesGate.Indicators,
      NervesGate.Hardware,
      {Task.Supervisor, name: NervesGate.PluginTasks},
      NervesGate.Storage,
      NervesGate.IO,
      # Owns manual output claims; restarts with I/O, which clears them anyway.
      NervesGate.IO.Manual,
      # Plugins start after everything they call while starting. Views come later,
      # so a UI or projection restart never restarts plugins.
      NervesGate.SDKBackend,
      NervesGate.Plugins,
      NervesGate.ProjectionServer,
      NervesGateWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: NervesGate.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @host Application.compile_env(:nerves_gate, :target) == :host

  @impl true
  def start(_type, _args) do
    children =
      [{Phoenix.PubSub, [name: NervesGate.PubSub]}] ++
        backend_children() ++ dev_children() ++ [NervesGateWeb.Endpoint]

    NervesGate.Distribution.configure_cookie()
    Supervisor.start_link(children, strategy: :rest_for_one, name: NervesGate.Supervisor)
  end

  if @host do
    # The host serves the UI only. No device services, tables or simulators.
    defp backend_children do
      if is_nil(Application.get_env(:nerves_gate, :backend_node)),
        do: raise("Host mode requires a device backend. Run mix dev.ec100 or mix dev.qemu.")

      unless Node.alive?(),
        do: raise("Start the remote UI with elixir --name <name@address> -S mix phx.server")

      []
    end
  else
    defp backend_children do
      NervesGate.Network.Vintage.prepare_routing()

      [
        {PropertyTable, name: NervesGate.Properties},
        NervesGate.Network,
        NervesGate.Remote,
        NervesGate.Equipment,
        NervesGate.Indicators,
        NervesGate.Buses,
        NervesGate.ProjectionServer
      ]
    end
  end

  if Application.compile_env(:nerves_gate, :dev_tests, false) do
    defp dev_children, do: [NervesGate.QemuTests]
  else
    defp dev_children, do: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

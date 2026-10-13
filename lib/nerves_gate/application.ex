defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @backend_node Application.compile_env(:nerves_gate, :backend_node)
  @host_ui Application.compile_env(:nerves_gate, :target) == :host

  @impl true
  def start(_type, _args) do
    if @host_ui and is_nil(@backend_node),
      do: raise("Host mode requires a device backend. Run mix dev.ec100 or mix dev.qemu.")

    NervesGate.Distribution.configure_cookie()

    children =
      [{Phoenix.PubSub, [name: NervesGate.PubSub]}] ++
        backend_children() ++ [NervesGateWeb.Endpoint]

    Supervisor.start_link(children, strategy: :rest_for_one, name: NervesGate.Supervisor)
  end

  if @backend_node do
    # The host serves the UI only. No device services, tables or simulators.
    defp backend_children do
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
        NervesGate.Buses
      ]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

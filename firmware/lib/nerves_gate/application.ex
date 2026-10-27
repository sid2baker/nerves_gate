defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_primary_filter(
      :cellular_credentials,
      {&NervesGate.Cellular.filter_log/2, nil}
    )

    children =
      [{Phoenix.PubSub, [name: NervesGate.PubSub]}, NervesGate.Plugins.UI] ++
        Application.fetch_env!(:nerves_gate, :services)

    NervesGate.Distribution.configure_cookie()
    Supervisor.start_link(children, strategy: :rest_for_one, name: NervesGate.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    for service <- Application.fetch_env!(:nerves_gate, :services),
        is_atom(service),
        function_exported?(service, :config_change, 2) do
      service.config_change(changed, removed)
    end

    :ok
  end
end

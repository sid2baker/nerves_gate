defmodule NervesGate.Remote.Host do
  @moduledoc "In-memory Tailscale preview. Never starts, attaches to, or changes a workstation daemon."
  use Agent
  @behaviour NervesGate.Remote.Adapter
  alias NervesGate.Observations

  @impl true
  def observations(server), do: [{Observations.table(), Observations.host("remote", server)}]

  def start_link(opts \\ []),
    do: Agent.start_link(&defaults/0, name: Keyword.get(opts, :name, __MODULE__))

  def defaults do
    Map.merge(NervesGate.Remote.unavailable(), %{
      available: true,
      simulated: true,
      state: "offline",
      auth_state: "needs_login",
      hostname: "nerves-gate",
      advertised_routes: [],
      sharing: %{ready: true, uncertain: []}
    })
  end

  @impl true
  def snapshot(server), do: Agent.get(server, & &1)

  @impl true
  def execute(:connect, %{hostname: name}, server) do
    update(
      server,
      &Map.merge(&1, %{
        hostname: name,
        state: "online",
        auth_state: "authenticated",
        ipv4: "100.64.0.10",
        version: "simulated"
      })
    )
  end

  def execute(:configure, %{hostname: name}, server),
    do: update(server, &%{&1 | hostname: name})

  def execute(:disconnect, _, server) do
    update(server, &%{&1 | state: "offline", auth_state: "stopped"})
  end

  def execute(operation, params, server)
      when operation in [:sharing_enable, :sharing_disable, :sharing_sync] do
    with {:ok, routes} <-
           NervesGate.Remote.Routes.change(operation, params, snapshot(server).advertised_routes),
         :ok <- update(server, &%{&1 | advertised_routes: routes}) do
      {:ok, routes}
    end
  end

  @impl true
  def login_url(_), do: nil

  def simulate(changes, server \\ __MODULE__) do
    update(server, fn _ -> Map.merge(defaults(), changes) end)
  end

  defp update(server, fun) do
    Agent.update(server, fn state ->
      next = fun.(state)

      Observations.put(
        Observations.host("remote", self()),
        NervesGate.Remote.Policy.sanitize(next)
      )

      next
    end)
  end
end

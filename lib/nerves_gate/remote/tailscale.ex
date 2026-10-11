defmodule NervesGate.Remote.Tailscale do
  @moduledoc "Firmware adapter. The daemon owns identity and settings; never copy credentials into gateway config."
  @behaviour NervesGate.Remote.Adapter

  @impl true
  def observations(_) do
    paths = [
      ["state"],
      ["auth", "state"],
      ["hostname"],
      ["dns_name"],
      ["ipv4"],
      ["version"],
      ["health"],
      ["configuration", "value"]
    ]

    Enum.map(paths, &{Tailscale.Properties, &1})
  end

  @impl true
  def snapshot(_) do
    if :ets.whereis(Tailscale.Properties) == :undefined,
      do: NervesGate.Remote.Policy.unavailable(),
      else: daemon_snapshot()
  end

  defp daemon_snapshot do
    config = Tailscale.get_configuration()
    state = Tailscale.get(["state"], :unavailable)

    %{
      available: state != :unavailable and is_map(config),
      state: to_string(state),
      auth_state: to_string(Tailscale.get(["auth", "state"], :unknown)),
      hostname: (config && config[:hostname]) || Tailscale.get(["hostname"]),
      dns_name: Tailscale.get(["dns_name"]),
      ipv4: ip(Tailscale.get(["ipv4"])),
      version: Tailscale.get(["version"]),
      advertised_routes: config && config[:advertise_routes],
      health: Tailscale.get(["health"], [])
    }
  end

  @impl true
  def execute(:connect, %{hostname: hostname}, _) do
    # Don't let Tailscale take DNS away from VintageNet. Preserve all other preferences,
    # especially existing route/Serve settings installed outside this UI.
    with :ok <- Tailscale.update_configuration(%{hostname: hostname, accept_dns: false}),
         do: Tailscale.login(timeout: 30_000)
  end

  def execute(:configure, %{hostname: hostname}, _),
    do: Tailscale.update_configuration(%{hostname: hostname, accept_dns: false})

  def execute(:disconnect, _, _), do: Tailscale.logout()

  @impl true
  def login_url(_) do
    if :ets.whereis(Tailscale.Properties) != :undefined, do: Tailscale.get(["auth", "url"])
  end

  defp ip(nil), do: nil
  defp ip(value), do: value |> :inet.ntoa() |> to_string()
end

defmodule NervesGate.Remote.Tailscaled do
  @moduledoc "Firmware adapter. The daemon owns identity and settings; never copy credentials into gateway config."

  alias NervesGate.Remote.Policy

  def observations do
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

    Enum.map(paths, &{Tailscaled.Properties, &1})
  end

  def snapshot do
    if :ets.whereis(Tailscaled.Properties) == :undefined do
      NervesGate.Remote.Policy.unavailable()
    else
      daemon_snapshot()
    end
  end

  defp daemon_snapshot do
    config = Tailscaled.get_configuration()
    state = Tailscaled.get(["state"], :unavailable)

    %{
      available: state != :unavailable and is_map(config),
      state: to_string(state),
      auth_state: to_string(Tailscaled.get(["auth", "state"], :unknown)),
      hostname: (config && config[:hostname]) || Tailscaled.get(["hostname"]),
      dns_name: Tailscaled.get(["dns_name"]),
      ipv4: ip(Tailscaled.get(["ipv4"])),
      version: Tailscaled.get(["version"]),
      advertised_routes: config && config[:advertise_routes],
      health: Tailscaled.get(["health"], [])
    }
  end

  def execute(:connect, %{hostname: hostname} = params) do
    with :ok <- Tailscaled.update_configuration(%{hostname: hostname, accept_dns: false}) do
      connect(params)
    end
  end

  def execute(:configure, %{hostname: hostname}),
    do: Tailscaled.update_configuration(%{hostname: hostname, accept_dns: false})

  def execute(:disconnect, _) do
    Tailscaled.down()
  end

  def execute(:serve, %{dns_name: dns_name}) do
    # Recheck inside the worker: the identity may change after admission.
    case snapshot() |> Policy.sanitize() |> Policy.serve_dns_name(nil) do
      ^dns_name when is_binary(dns_name) ->
        Tailscaled.update_configuration(%{
          serve: [%{https: 443, to: "http://127.0.0.1:4000"}]
        })

      _ ->
        {:error, :serve_not_ready}
    end
  end

  def execute(operation, params)
      when operation in [:sharing_enable, :sharing_disable, :sharing_sync, :sharing_claim] do
    # Refresh is a serialized Controller read, not a write replay. Earlier
    # accepted changes finish first, even if their original caller was killed.
    # Only the route list is ever patched here.
    with :ok <- Tailscaled.refresh_configuration(),
         config when is_map(config) <- Tailscaled.get_configuration(),
         {:ok, routes} <-
           NervesGate.Remote.Sharing.change(operation, params, config.advertise_routes),
         :ok <- prepare_route_ownership(operation, params),
         :ok <- write_routes(operation, routes),
         %{advertise_routes: ^routes} <- Tailscaled.get_configuration() do
      {:ok, routes}
    else
      {:error, %{code: "route_in_use"}} = rejected ->
        rejected

      _ ->
        {:error,
         %{
           code: "sharing_unknown",
           message:
             "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
         }}
    end
  end

  defp prepare_route_ownership(:sharing_claim, %{scope: scope}),
    do: NervesGate.Network.Local.mark_advertising(scope)

  defp prepare_route_ownership(_, _), do: :ok

  defp write_routes(:sharing_sync, _), do: :ok
  defp write_routes(_, routes), do: Tailscaled.update_configuration(%{advertise_routes: routes})

  def login_url do
    if :ets.whereis(Tailscaled.Properties) != :undefined do
      Tailscaled.get(["auth", "url"])
    end
  end

  defp connect(%{auth_key: key}) do
    # Subscribe only to the state, never credential-bearing auth properties.
    :ok = Tailscaled.subscribe(["auth", "state"])
    with :ok <- Tailscaled.login(auth_key: key), do: await_key_login()
  end

  defp connect(_) do
    if Tailscaled.get(["auth", "state"]) in [:authenticated, :stopped, :needs_approval],
      do: Tailscaled.up(),
      else: Tailscaled.login(timeout: 30_000)
  end

  # Remote owns the worker's overall deadline and cancellation.
  defp await_key_login do
    case Tailscaled.get(["auth", "state"]) do
      :authenticated ->
        :ok

      :needs_approval ->
        {:error, :needs_approval}

      :error ->
        {:error, :authentication_failed}

      _ ->
        receive do
          {Tailscaled, ["auth", "state"], _, _, _} -> await_key_login()
        after
          1000 -> await_key_login()
        end
    end
  end

  defp ip(nil), do: nil
  defp ip(value), do: value |> :inet.ntoa() |> to_string()
end

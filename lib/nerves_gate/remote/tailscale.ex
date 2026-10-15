defmodule NervesGate.Remote.Tailscale do
  @moduledoc "Firmware adapter. The daemon owns identity and settings; never copy credentials into gateway config."
  @behaviour NervesGate.Remote.Adapter
  alias NervesGate.Remote.Policy

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
  def execute(:connect, %{hostname: hostname} = params, _) do
    with :ok <- Tailscale.update_configuration(%{hostname: hostname, accept_dns: false}) do
      connect(params)
    end
  end

  def execute(:configure, %{hostname: hostname}, _),
    do: Tailscale.update_configuration(%{hostname: hostname, accept_dns: false})

  def execute(:disconnect, _, _) do
    Tailscale.down()
  end

  def execute(:serve, %{dns_name: dns_name}, _) do
    # Recheck inside the worker: the identity may change after admission.
    case snapshot(nil) |> Policy.sanitize() |> Policy.serve_dns_name(nil) do
      ^dns_name when is_binary(dns_name) ->
        Tailscale.update_configuration(%{
          serve: [%{https: 443, to: "http://127.0.0.1:4000"}]
        })

      _ ->
        {:error, :serve_not_ready}
    end
  end

  def execute(operation, params, _)
      when operation in [:sharing_enable, :sharing_disable, :sharing_sync] do
    # An empty update is a Controller mailbox barrier and fresh readback, not a
    # replay. Earlier accepted changes finish before this read, even if their
    # original caller was killed. Only the route list is ever patched here.
    with :ok <- Tailscale.update_configuration(%{}),
         config when is_map(config) <- Tailscale.get_configuration(),
         {:ok, routes} <-
           NervesGate.Remote.Sharing.change(operation, params, config.advertise_routes),
         :ok <- write_routes(operation, routes),
         %{advertise_routes: ^routes} <- Tailscale.get_configuration() do
      {:ok, routes}
    else
      _ -> {:error, :sharing_unknown}
    end
  end

  defp write_routes(:sharing_sync, _), do: :ok
  defp write_routes(_, routes), do: Tailscale.update_configuration(%{advertise_routes: routes})

  @impl true
  def login_url(_) do
    if :ets.whereis(Tailscale.Properties) != :undefined, do: Tailscale.get(["auth", "url"])
  end

  defp connect(%{auth_key: key}) do
    # Subscribe only to the state, never credential-bearing auth properties.
    :ok = Tailscale.subscribe(["auth", "state"])
    with :ok <- Tailscale.login(auth_key: key), do: await_key_login()
  end

  defp connect(_) do
    if Tailscale.get(["auth", "state"]) in [:authenticated, :stopped, :needs_approval],
      do: Tailscale.up(),
      else: Tailscale.login(timeout: 30_000)
  end

  # Remote owns the worker's overall deadline and cancellation.
  defp await_key_login do
    case Tailscale.get(["auth", "state"]) do
      :authenticated ->
        :ok

      :needs_approval ->
        {:error, :needs_approval}

      :error ->
        {:error, :authentication_failed}

      _ ->
        receive do
          %PropertyTable.Event{} -> await_key_login()
        after
          1000 -> await_key_login()
        end
    end
  end

  defp ip(nil), do: nil
  defp ip(value), do: value |> :inet.ntoa() |> to_string()
end

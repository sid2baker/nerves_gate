defmodule NervesGate.Tailnet.Observation do
  @moduledoc "Pure projection of typed Tailscale status, health, peers, and route state."

  alias NervesGate.Tailnet.{Address, Status}

  @type t :: Status.t()

  @spec project(Tailscale.Status.t(), map(), Tailscale.Health.t()) :: t()
  def project(
        %Tailscale.Status{} = source,
        routes \\ unavailable_routes(),
        health \\ Tailscale.Health.initial()
      ) do
    ipv4 = valid_ipv4(source.ipv4)
    online = source.online == true and not is_nil(ipv4)

    peers = Enum.map(source.peers, &project_peer/1)

    nodes =
      ([%{hostname: source.hostname, ipv4: ipv4, online: online, self: true}] ++
         for(
           %{hostname: "nervesgate-" <> _rest} = peer <- peers,
           do: Map.take(peer, [:hostname, :ipv4, :online]) |> Map.put(:self, false)
         ))
      |> Enum.reject(&is_nil(&1.ipv4))

    %Status{
      state: if(online, do: :online, else: :connecting),
      online: online,
      authenticated: source.authenticated,
      hostname: source.hostname,
      ipv4: ipv4,
      peers: peers,
      nodes: nodes,
      subnet_router: routes,
      health: health,
      error: if(online, do: nil, else: status_error(source))
    }
  end

  @spec offline(atom(), Tailscale.Health.t()) :: t()
  def offline(reason, health \\ Tailscale.Health.initial()) do
    %Status{
      state: :disabled,
      online: false,
      authenticated: :unknown,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      subnet_router: unavailable_routes(),
      health: health,
      error: reason
    }
  end

  @spec unavailable_routes() :: map()
  def unavailable_routes,
    do: %{advertised: [], approved: [], primary: [], error: :unavailable}

  @spec route_status((-> term()), map()) :: map()
  def route_status(read, previous \\ unavailable_routes()) do
    case read.() do
      {:ok, routes} -> Map.put(routes, :error, nil)
      {:error, _reason} -> previous
    end
  end

  defp project_peer(peer) do
    %{
      online: peer.online == true,
      hostname: peer.hostname,
      dns_name: peer.dns_name,
      ipv4: valid_ipv4(peer.ipv4),
      user_id: peer.id,
      user: nil
    }
  end

  defp valid_ipv4(address) when is_binary(address) do
    if match?({:ok, _parsed}, Address.parse_ipv4(address)), do: address
  end

  defp valid_ipv4(_address), do: nil

  defp status_error(%{backend_state: :needs_login}), do: :needs_login
  defp status_error(%{backend_state: :needs_machine_auth}), do: :needs_machine_auth
  defp status_error(%{backend_state: :stopped}), do: :stopped
  defp status_error(%{online: true}), do: :address_unavailable
  defp status_error(_source), do: :status_unavailable
end

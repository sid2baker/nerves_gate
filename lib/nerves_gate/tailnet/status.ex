defmodule NervesGate.Tailnet.Status do
  @moduledoc "Secret-free public Tailnet reality; private observation phases are excluded."

  @enforce_keys [
    :state,
    :online,
    :authenticated,
    :hostname,
    :ipv4,
    :peers,
    :nodes,
    :subnet_router,
    :health,
    :error
  ]
  defstruct [
    :state,
    :online,
    :authenticated,
    :hostname,
    :ipv4,
    :peers,
    :nodes,
    :subnet_router,
    :health,
    :error
  ]

  @type t :: %__MODULE__{
          state: :needs_auth | :connecting | :online,
          online: boolean(),
          authenticated: boolean() | :unknown,
          hostname: String.t() | nil,
          ipv4: String.t() | nil,
          peers: [map()],
          nodes: [map()],
          subnet_router: map(),
          health: map() | Tailscale.Health.t(),
          error: atom() | nil
        }
end

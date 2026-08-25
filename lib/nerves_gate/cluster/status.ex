defmodule NervesGate.Cluster.Status do
  @moduledoc "Secret-free public cluster state."

  @enforce_keys [:state, :enabled, :group, :online, :node, :connected, :candidates, :groups]
  defstruct [:state, :enabled, :group, :online, :node, :connected, :candidates, :groups]

  @type t :: %__MODULE__{
          state: :disabled | :blocked | :online | :backoff,
          enabled: boolean(),
          group: String.t() | nil,
          online: boolean(),
          node: node() | String.t() | nil,
          connected: [node() | String.t()],
          candidates: [map()],
          groups: [map()]
        }
end

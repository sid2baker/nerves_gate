defmodule NervesGateSDK.Hardware do
  @moduledoc "Read the actual managed caller's enabled exclusive port assignments. Opens no handles. Plugins supervise their own transport libraries."
  alias NervesGateSDK.Backend

  defmodule Port do
    @moduledoc "An allowlisted assigned resource. Presence is not equipment readiness."
    @enforce_keys [:id, :kind, :present?]
    defstruct [:id, :kind, :present?, :path, :interface]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :serial | :can | :ethernet,
            present?: boolean(),
            path: String.t() | nil,
            interface: String.t() | nil
          }
  end

  defmodule Candidate do
    @moduledoc "Read-only port choice, not permission to open or configure it."
    @enforce_keys [:id, :kind, :present?, :enabled?]
    defstruct [:id, :kind, :present?, :enabled?, :assigned_plugin]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :serial | :can | :ethernet,
            present?: boolean(),
            enabled?: boolean(),
            assigned_plugin: String.t() | nil
          }
  end

  @doc "Read hardware candidates for setup. Administrative review grants assignments; this query does not."
  @spec candidates() :: {:ok, [Candidate.t()]} | {:error, term()}
  def candidates, do: Backend.call(:hardware_candidates, [])

  @spec resources() :: {:ok, [Port.t()]} | {:error, term()}
  def resources, do: Backend.call(:hardware_resources, [])
end

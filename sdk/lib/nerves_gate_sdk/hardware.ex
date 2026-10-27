defmodule NervesGateSDK.Hardware do
  @moduledoc "Read the actual managed caller's enabled exclusive port assignments. Opens no handles. Plugins supervise their own transport libraries."
  alias NervesGateSDK.Backend

  defmodule Port do
    @moduledoc "An allowlisted assigned resource. Presence is not equipment readiness."
    @enforce_keys [:id, :kind, :present?]
    defstruct [:id, :kind, :present?, :path, :interface]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :serial | :can,
            present?: boolean(),
            path: String.t() | nil,
            interface: String.t() | nil
          }
  end

  @spec resources() :: {:ok, [Port.t()]} | {:error, term()}
  def resources, do: Backend.call(:hardware_resources, [])
end

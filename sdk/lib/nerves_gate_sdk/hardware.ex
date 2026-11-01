defmodule NervesGateSDK.Hardware do
  @moduledoc """
  Read the actual managed caller's enabled exclusive hardware assignments. Opens no
  handles. Plugins supervise their own transport libraries.

  A resource's `kind` says which class of plugin may own it. Boards declare their
  resources; plugins declare the kinds they support in `nerves_gate_hardware`.
  """
  alias NervesGateSDK.Backend

  @kinds [:ethernet, :can, :rs485, :iotrouter_expansion]

  @typedoc "Which class of plugin may own the resource."
  @type kind :: :ethernet | :can | :rs485 | :iotrouter_expansion

  @doc "Every kind a board may declare and a plugin may support."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  defmodule Port do
    @moduledoc """
    An assigned resource. Presence is not equipment readiness. `path` is the device
    node for serial-like resources, `interface` the network interface for CAN and
    Ethernet, and `gpios` the named GPIO lines that belong to the resource.
    """
    @enforce_keys [:id, :kind, :label, :present?]
    defstruct [:id, :kind, :label, :present?, :path, :interface, gpios: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: NervesGateSDK.Hardware.kind(),
            label: String.t(),
            present?: boolean(),
            path: String.t() | nil,
            interface: String.t() | nil,
            gpios: %{optional(atom()) => String.t()}
          }
  end

  defmodule Candidate do
    @moduledoc "Read-only resource choice, not permission to open or configure it."
    @enforce_keys [:id, :kind, :label, :present?, :enabled?]
    defstruct [:id, :kind, :label, :present?, :enabled?, :assigned_plugin]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: NervesGateSDK.Hardware.kind(),
            label: String.t(),
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

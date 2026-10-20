defmodule NervesGateSDK.Equipment do
  @moduledoc "Read-only observations of attached equipment."
  alias NervesGateSDK.Backend

  defmodule Device do
    @moduledoc "Public equipment identity and reachability."
    @enforce_keys [:id, :interface]
    defstruct [:id, :interface, :label, :address, reachable?: false]

    @type t :: %__MODULE__{
            id: String.t(),
            interface: String.t(),
            label: String.t() | nil,
            address: String.t() | nil,
            reachable?: boolean()
          }
  end

  @spec list() :: {:ok, [Device.t()]} | {:error, term()}
  def list, do: Backend.call(:equipment_list, [])
end

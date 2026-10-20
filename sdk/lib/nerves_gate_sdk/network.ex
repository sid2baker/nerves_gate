defmodule NervesGateSDK.Network do
  @moduledoc "Read-only network observations. Network configuration belongs to the platform."
  alias NervesGateSDK.Backend

  defmodule Interface do
    @moduledoc "A public network observation, without platform configuration."
    @enforce_keys [:id, :kind, :state]
    defstruct [:id, :kind, :state, addresses: [], internet?: false]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :ethernet | :cellular | :wifi | :usb | :other,
            state: :up | :down | :unknown,
            addresses: [String.t()],
            internet?: boolean()
          }
  end

  @spec interfaces() :: {:ok, [Interface.t()]} | {:error, term()}
  def interfaces, do: Backend.call(:network_interfaces, [])
end

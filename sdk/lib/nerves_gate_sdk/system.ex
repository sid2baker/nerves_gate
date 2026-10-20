defmodule NervesGateSDK.System do
  @moduledoc "Read-only device identity and runtime information."
  alias NervesGateSDK.Backend

  defmodule Info do
    @moduledoc "Public device identity. No credentials or distribution settings."
    @enforce_keys [:id, :model, :firmware_version, :sdk_version]
    defstruct [:id, :model, :firmware_version, :sdk_version, :uptime_ms]

    @type t :: %__MODULE__{
            id: String.t(),
            model: String.t(),
            firmware_version: String.t(),
            sdk_version: String.t(),
            uptime_ms: non_neg_integer() | nil
          }
  end

  @spec info() :: {:ok, Info.t()} | {:error, term()}
  def info, do: Backend.call(:system_info, [])
end

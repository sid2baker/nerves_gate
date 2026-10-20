defmodule NervesGateSDK.RS485 do
  @moduledoc """
  Exclusive, process-owned RS485 sessions. Claims are released on owner exit.
  Receive data arrives as Events.Event with topic `{:rs485, port}` and binary value.
  The platform owns serial settings; applications cannot open Linux devices.
  """
  alias NervesGateSDK.Backend

  defmodule Port do
    @moduledoc "A logical RS485 port and its availability."
    @enforce_keys [:id, :available?]
    defstruct [:id, :available?, claimed?: false]
    @type t :: %__MODULE__{id: String.t(), available?: boolean(), claimed?: boolean()}
  end

  @spec ports() :: {:ok, [Port.t()]} | {:error, term()}
  def ports, do: Backend.call(:rs485_ports, [])

  @spec claim(String.t()) :: {:ok, reference()} | {:error, term()}
  def claim(port) when is_binary(port), do: Backend.call(:rs485_claim, [port])
  def claim(_), do: {:error, :invalid_port}

  @spec write(reference(), binary()) :: :ok | {:error, term()}
  def write(claim, data) when is_reference(claim) and is_binary(data) and byte_size(data) <= 4096,
    do: Backend.call(:rs485_write, [claim, data])

  def write(_, _), do: {:error, :invalid_write}

  @spec release(reference()) :: :ok | {:error, term()}
  def release(claim) when is_reference(claim), do: Backend.call(:rs485_release, [claim])
  def release(_), do: {:error, :invalid_claim}
end

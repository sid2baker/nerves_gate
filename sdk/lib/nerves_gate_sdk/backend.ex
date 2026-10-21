defmodule NervesGateSDK.Backend do
  @moduledoc """
  Implemented by device firmware, including firmware running inside QEMU.
  The host simulator does not provide an in-memory hardware backend.

  `call/2` runs in the caller's process. Implementations must preserve caller
  ownership when forwarding subscriptions or RS485 claims to another process.
  Backends return SDK-owned structs and never expose private domain state.
  """

  @type operation ::
          :system_info
          | :network_interfaces
          | :events_subscribe
          | :events_unsubscribe
          | :storage_status
          | :storage_data_dir
          | :can_interfaces
          | :can_send
          | :can_subscribe
          | :can_unsubscribe
          | :rs485_ports
          | :rs485_claim
          | :rs485_write
          | :rs485_release
          | :equipment_list

  @callback call(operation(), list()) :: :ok | {:ok, term()} | {:error, term()}

  @doc false
  def call(operation, arguments) do
    case Application.get_env(:nerves_gate_sdk, :backend) do
      nil -> {:error, :backend_not_configured}
      backend -> backend.call(operation, arguments)
    end
  end
end

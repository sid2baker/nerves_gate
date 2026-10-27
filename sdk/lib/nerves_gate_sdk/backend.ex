defmodule NervesGateSDK.Backend do
  @moduledoc """
  Fixed runtime bridge to `NervesGate.SDKBackend`, supplied by gateway firmware
  on both physical and QEMU devices. There is no backend selection or host
  hardware emulation. Without the firmware module, calls return
  `{:error, :runtime_unavailable}`.

  `call/2` invokes the firmware entry point in the caller's process. The firmware
  must preserve caller ownership when forwarding subscriptions or resource claims.
  Its entry point implements this callback and returns SDK-owned structs, never
  private domain state.
  """

  @type operation ::
          :system_info
          | :network_interfaces
          | :network_claim_local
          | :network_local_status
          | :network_advertise_local
          | :network_release_local
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

  @callback call(operation(), list()) :: :ok | {:ok, term()} | {:error, term()}

  @doc false
  def call(operation, arguments) do
    if Code.ensure_loaded?(NervesGate.SDKBackend) do
      # Runtime-only dependency: the standalone SDK does not compile firmware.
      apply(NervesGate.SDKBackend, :call, [operation, arguments])
    else
      {:error, :runtime_unavailable}
    end
  end
end

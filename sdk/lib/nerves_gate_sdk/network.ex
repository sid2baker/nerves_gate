defmodule NervesGateSDK.Network do
  @moduledoc "Network observations and process-owned access to explicitly enabled, isolated local Ethernet. Internet and management remain platform-owned."
  alias NervesGateSDK.Backend

  defmodule Interface do
    @moduledoc "A public network observation, without platform configuration."
    @enforce_keys [:id, :kind, :state]
    defstruct [
      :id,
      :kind,
      :state,
      addresses: [],
      internet?: false,
      plugin_enabled?: false,
      assigned_plugin: nil,
      claimed?: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :ethernet | :cellular | :wifi | :usb | :other,
            state: :up | :down | :unknown,
            addresses: [String.t()],
            internet?: boolean(),
            plugin_enabled?: boolean(),
            assigned_plugin: String.t() | nil,
            claimed?: boolean()
          }
  end

  defmodule Local do
    @moduledoc "A caller-private local network lease. Its reference must never enter public projections or logs."
    @enforce_keys [:ref, :interface, :address, :prefix, :subnet, :phase]
    defstruct [
      :ref,
      :interface,
      :address,
      :prefix,
      :subnet,
      :phase,
      :error,
      ready?: false,
      advertised?: nil,
      approval: :unknown
    ]

    @type t :: %__MODULE__{
            ref: reference(),
            interface: String.t(),
            address: String.t(),
            prefix: 1..30,
            subnet: String.t(),
            phase: atom(),
            error: String.t() | nil,
            ready?: boolean(),
            advertised?: boolean() | nil,
            approval: :unknown
          }
  end

  @doc "Claim an enabled Ethernet interface exclusively assigned to this managed plugin. No DHCP, default route, DNS or advertisement is started. The calling process owns the claim."
  @spec claim_local(String.t(), String.t(), 1..30) :: {:ok, reference()} | {:error, term()}
  def claim_local(interface, address, prefix)
      when interface in ["eth0", "eth1"] and is_binary(address) and is_integer(prefix) and
             prefix in 1..30,
      do: Backend.call(:network_claim_local, [interface, address, prefix])

  def claim_local(_, _, _), do: {:error, :invalid_local_network}

  @doc "Read this caller's lease, including an uncertain claim whose original reply was lost."
  @spec local_status() :: {:ok, Local.t() | nil} | {:error, term()}
  def local_status, do: Backend.call(:network_local_status, [])

  @doc "Explicitly advertise this claim's ready subnet through the platform's enrolled Tailscale. Approval and reachability remain unverified. Never retried automatically."
  def advertise_local(ref) when is_reference(ref),
    do: Backend.call(:network_advertise_local, [ref])

  def advertise_local(_), do: {:error, :invalid_claim}

  @doc "Withdraw only the claim's owned advertisement, then remove its temporary address and release access. Caller death also schedules cleanup. An incomplete cleanup blocks reuse."
  def release_local(ref) when is_reference(ref), do: Backend.call(:network_release_local, [ref])
  def release_local(_), do: {:error, :invalid_claim}

  @spec interfaces() :: {:ok, [Interface.t()]} | {:error, term()}
  def interfaces, do: Backend.call(:network_interfaces, [])
end

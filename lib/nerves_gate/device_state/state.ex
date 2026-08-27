defmodule NervesGate.DeviceState.State do
  @moduledoc """
  Canonical secret-free public state for one gateway.

  The authoritative server and every consumer hold the same `%State{}`. Public
  state changes only by applying ordered `t:event/0` values. Applying an event
  is pure and never returns commands or performs runtime work.

  A `nil` subsystem slice means that its owner has not hydrated the current
  DeviceState boot. It is distinct from an explicit offline, disabled, blocked,
  or failed state.
  """

  @sources [
    :device,
    :firmware,
    :configuration,
    :commissioning,
    :internet,
    :tailnet,
    :subnet_router,
    :ssh,
    :cluster,
    :alarms
  ]

  @essential_sources [
    :device,
    :firmware,
    :configuration,
    :commissioning,
    :internet,
    :tailnet,
    :subnet_router,
    :ssh,
    :cluster,
    :alarms
  ]

  defstruct device: nil,
            firmware: nil,
            configuration: nil,
            commissioning: nil,
            internet: nil,
            tailnet: nil,
            subnet_router: nil,
            ssh: nil,
            cluster: nil,
            alarms: nil

  @type source ::
          :device
          | :firmware
          | :configuration
          | :commissioning
          | :internet
          | :tailnet
          | :subnet_router
          | :ssh
          | :cluster
          | :alarms

  @type event ::
          {:state_reported, :device, map()}
          | {:state_reported, :firmware, NervesGate.Firmware.Status.t()}
          | {:state_reported, :configuration, map()}
          | {:state_reported, :commissioning, NervesGate.Commissioning.Status.t()}
          | {:state_reported, :internet, NervesGate.Internet.Status.t()}
          | {:state_reported, :tailnet, NervesGate.Tailnet.Status.t()}
          | {:state_reported, :subnet_router, NervesGate.SubnetRouter.Status.t()}
          | {:state_reported, :ssh, NervesGate.SSH.Status.t()}
          | {:state_reported, :cluster, NervesGate.Cluster.Status.t()}
          | {:state_reported, :alarms, [map()]}

  @type t :: %__MODULE__{
          device: map() | nil,
          firmware: NervesGate.Firmware.Status.t() | nil,
          configuration: map() | nil,
          commissioning: NervesGate.Commissioning.Status.t() | nil,
          internet: NervesGate.Internet.Status.t() | nil,
          tailnet: NervesGate.Tailnet.Status.t() | nil,
          subnet_router: NervesGate.SubnetRouter.Status.t() | nil,
          ssh: NervesGate.SSH.Status.t() | nil,
          cluster: NervesGate.Cluster.Status.t() | nil,
          alarms: [map()] | nil
        }

  @doc "Returns an empty, unhydrated public state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the finite set of public slice owners."
  @spec sources() :: [source()]
  def sources, do: @sources

  @doc "Returns slices required before the initial boot handshake is complete."
  @spec essential_sources() :: [source()]
  def essential_sources, do: @essential_sources

  @doc "Whether every essential owner has reported state for this DeviceState boot."
  @spec hydrated?(t()) :: boolean()
  def hydrated?(%__MODULE__{} = state) do
    Enum.all?(@essential_sources, &(not is_nil(Map.fetch!(state, &1))))
  end

  @doc "Purely applies one public event."
  @spec apply_event(t(), event()) :: {:ok, t()} | :error
  def apply_event(%__MODULE__{} = state, {:state_reported, source, value})
      when source in @sources do
    if valid_slice?(source, value), do: {:ok, Map.replace!(state, source, value)}, else: :error
  end

  def apply_event(%__MODULE__{}, _event), do: :error

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state), do: Map.from_struct(state)

  defp valid_slice?(:alarms, alarms) when is_list(alarms) do
    Enum.all?(alarms, fn
      %{id: id, description: description, level: level}
      when is_binary(id) and is_binary(description) and is_atom(level) ->
        true

      _invalid ->
        false
    end)
  end

  defp valid_slice?(:device, %{device_id: id, name: name, firmware_version: version})
       when is_binary(id) and is_binary(name) and is_binary(version),
       do: true

  defp valid_slice?(:firmware, %NervesGate.Firmware.Status{}), do: true
  defp valid_slice?(:configuration, value) when is_map(value), do: true
  defp valid_slice?(:commissioning, %NervesGate.Commissioning.Status{}), do: true
  defp valid_slice?(:internet, %NervesGate.Internet.Status{}), do: true
  defp valid_slice?(:tailnet, %NervesGate.Tailnet.Status{}), do: true
  defp valid_slice?(:subnet_router, %NervesGate.SubnetRouter.Status{}), do: true
  defp valid_slice?(:ssh, %NervesGate.SSH.Status{}), do: true
  defp valid_slice?(:cluster, %NervesGate.Cluster.Status{}), do: true
  defp valid_slice?(_source, _value), do: false
end

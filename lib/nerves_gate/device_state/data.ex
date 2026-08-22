defmodule NervesGate.DeviceState.Data do
  @moduledoc """
  Canonical, secret-free device state shared with all connected clients.

  The authoritative `NervesGate.DeviceState.Server` and every client replica
  keep the same `%Data{}`. All mutations go through the server first and are
  represented as operations. The server applies an operation and then
  broadcasts it, so every client applies the same pure transition in the same
  order while messages remain small.

  `apply_operation/2` has no direct side effects. It returns actions for the
  authoritative process to execute; current operations request a local state
  notification. Clients always discard actions.

  Boot identifiers, revisions, connection freshness, monitors, retries, and
  buffered messages are replication transport metadata and never belong to
  this structure. Credentials and other private runtime state are neither
  stored nor accepted by its operations.
  """

  @enforce_keys [:device_id, :name, :firmware_version]
  defstruct [
    :device_id,
    :name,
    :firmware_version,
    internet: %{status: :failed, reason: :starting},
    tailnet: %{
      status: :blocked,
      observed_status: :offline,
      authenticated: :unknown,
      hostname: nil,
      ipv4: nil
    },
    cluster: %{
      status: :disabled,
      runtime_status: :disabled,
      enabled: false,
      group: nil,
      node: nil,
      connected: []
    },
    alarms: []
  ]

  @type layer_status :: :online | :offline | :failed | :blocked | :disabled
  @type origin :: :bootstrap | :device | :internet | :tailnet | :cluster | :alarms

  @type internet :: %{
          status: :online | :failed,
          reason: term()
        }

  @type tailnet :: %{
          status: layer_status(),
          observed_status: :online | :offline,
          authenticated: boolean() | :unknown,
          hostname: String.t() | nil,
          ipv4: String.t() | nil
        }

  @type cluster :: %{
          status: layer_status(),
          runtime_status: :online | :failed | :disabled,
          enabled: boolean(),
          group: String.t() | nil,
          node: String.t() | nil,
          connected: [String.t()]
        }

  @type alarm :: %{
          id: String.t(),
          description: String.t(),
          level: atom()
        }

  @type t :: %__MODULE__{
          device_id: String.t(),
          name: String.t(),
          firmware_version: String.t(),
          internet: internet(),
          tailnet: tailnet(),
          cluster: cluster(),
          alarms: [alarm()]
        }

  @type operation ::
          {:set_name, origin(), String.t()}
          | {:set_internet, origin(), map()}
          | {:set_tailnet, origin(), map()}
          | {:set_cluster, origin(), map()}
          | {:set_alarm, origin(), map()}
          | {:clear_alarm, origin(), String.t()}

  @type action :: :broadcast

  @doc "Returns fresh canonical data for one device."
  @spec new(keyword()) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [
        :device_id,
        :name,
        :firmware_version,
        internet: %{status: :failed, reason: :starting},
        tailnet: %{},
        cluster: %{},
        alarms: []
      ])

    data = %__MODULE__{
      device_id: Keyword.fetch!(options, :device_id),
      name: Keyword.fetch!(options, :name),
      firmware_version: Keyword.fetch!(options, :firmware_version)
    }

    operations = [
      {:set_internet, :bootstrap, options[:internet]},
      {:set_tailnet, :bootstrap, options[:tailnet]},
      {:set_cluster, :bootstrap, options[:cluster]}
    ]

    data = Enum.reduce(operations, data, &apply_valid_operation!/2)

    Enum.reduce(options[:alarms], data, fn alarm, data ->
      apply_valid_operation!({:set_alarm, :bootstrap, alarm}, data)
    end)
  end

  @doc """
  Applies an operation as a pure state transition.

  Returns `{:ok, data, actions}` for a valid operation and `:error` for
  malformed or unknown operations. Actions are intended only for the
  authoritative server. Replicas apply the returned data and ignore actions.
  """
  @spec apply_operation(t(), operation()) :: {:ok, t(), [action()]} | :error
  def apply_operation(data, operation)

  def apply_operation(%__MODULE__{} = data, {:set_name, origin, name})
      when origin in [:bootstrap, :device] and is_binary(name) do
    wrap_ok(%{data | name: name}, :broadcast)
  end

  def apply_operation(%__MODULE__{} = data, {:set_internet, origin, internet})
      when origin in [:bootstrap, :internet] and is_map(internet) do
    with {:ok, internet} <- normalize_internet(internet) do
      data
      |> Map.put(:internet, internet)
      |> apply_dependencies()
      |> wrap_ok(:broadcast)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:set_tailnet, origin, tailnet})
      when origin in [:bootstrap, :tailnet] and is_map(tailnet) do
    with {:ok, tailnet} <- normalize_tailnet(tailnet) do
      data
      |> Map.put(:tailnet, tailnet)
      |> apply_dependencies()
      |> wrap_ok(:broadcast)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:set_cluster, origin, cluster})
      when origin in [:bootstrap, :cluster] and is_map(cluster) do
    with {:ok, cluster} <- normalize_cluster(cluster) do
      data
      |> Map.put(:cluster, cluster)
      |> apply_dependencies()
      |> wrap_ok(:broadcast)
    end
  end

  def apply_operation(
        %__MODULE__{} = data,
        {:set_alarm, origin, %{id: id, description: description, level: level} = alarm}
      )
      when origin in [:bootstrap, :alarms] and map_size(alarm) == 3 and is_binary(id) and
             is_binary(description) and is_atom(level) do
    alarm = %{id: id, description: description, level: level}

    alarms =
      data.alarms
      |> Enum.reject(&(&1.id == id))
      |> then(&[alarm | &1])
      |> Enum.sort_by(& &1.id)

    wrap_ok(%{data | alarms: alarms}, :broadcast)
  end

  def apply_operation(%__MODULE__{} = data, {:clear_alarm, origin, id})
      when origin in [:bootstrap, :alarms] and is_binary(id) do
    wrap_ok(%{data | alarms: Enum.reject(data.alarms, &(&1.id == id))}, :broadcast)
  end

  def apply_operation(%__MODULE__{}, _invalid_operation), do: :error

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = data), do: Map.from_struct(data)

  defp normalize_internet(internet) do
    status = Map.get(internet, :status, :failed)

    if only_keys?(internet, [:status, :reason]) and status in [:online, :failed] do
      {:ok, %{status: status, reason: Map.get(internet, :reason)}}
    else
      :error
    end
  end

  defp normalize_tailnet(tailnet) do
    observed_status = Map.get(tailnet, :observed_status, :offline)
    authenticated = Map.get(tailnet, :authenticated, :unknown)
    hostname = Map.get(tailnet, :hostname)
    ipv4 = Map.get(tailnet, :ipv4)

    if only_keys?(tailnet, [:observed_status, :authenticated, :hostname, :ipv4]) and
         observed_status in [:online, :offline] and authenticated in [true, false, :unknown] and
         optional_string?(hostname) and optional_string?(ipv4) do
      {:ok,
       %{
         status: observed_status,
         observed_status: observed_status,
         authenticated: authenticated,
         hostname: hostname,
         ipv4: ipv4
       }}
    else
      :error
    end
  end

  defp normalize_cluster(cluster) do
    enabled = Map.get(cluster, :enabled, false)
    default_status = if enabled, do: :failed, else: :disabled
    runtime_status = Map.get(cluster, :runtime_status, default_status)
    group = Map.get(cluster, :group)
    node = Map.get(cluster, :node)
    connected = Map.get(cluster, :connected, [])

    if only_keys?(cluster, [:runtime_status, :enabled, :group, :node, :connected]) and
         is_boolean(enabled) and runtime_status in [:online, :failed, :disabled] and
         optional_string?(group) and optional_string?(node) and is_list(connected) and
         Enum.all?(connected, &is_binary/1) do
      {:ok,
       %{
         status: runtime_status,
         runtime_status: runtime_status,
         enabled: enabled,
         group: group,
         node: node,
         connected: Enum.sort(connected)
       }}
    else
      :error
    end
  end

  defp apply_dependencies(data) do
    tailnet_status =
      if data.internet.status == :online,
        do: data.tailnet.observed_status,
        else: :blocked

    cluster_status =
      cond do
        not data.cluster.enabled -> :disabled
        data.internet.status != :online or tailnet_status != :online -> :blocked
        true -> data.cluster.runtime_status
      end

    %{
      data
      | tailnet: Map.put(data.tailnet, :status, tailnet_status),
        cluster: Map.put(data.cluster, :status, cluster_status)
    }
  end

  defp apply_valid_operation!(operation, data) do
    {:ok, data, _actions} = apply_operation(data, operation)
    data
  end

  defp wrap_ok(data, action), do: {:ok, data, [action]}
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp only_keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))
end

defmodule NervesGate.DeviceState.Public do
  @moduledoc "Pure, secret-free public device data and its deterministic operation reducer."

  @enforce_keys [:device_id, :name, :boot_id, :firmware_version]
  defstruct [
    :device_id,
    :name,
    :boot_id,
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
      runtime_status: :offline,
      enabled: false,
      node: nil,
      connected: []
    },
    alarms: []
  ]

  @type t :: %__MODULE__{
          device_id: String.t(),
          name: String.t(),
          boot_id: String.t(),
          firmware_version: String.t(),
          internet: map(),
          tailnet: map(),
          cluster: map(),
          alarms: [map()]
        }

  @type operation ::
          {:name_changed, String.t()}
          | {:internet_changed, map()}
          | {:tailnet_changed, map()}
          | {:cluster_changed, map()}
          | {:alarm_set, map()}
          | {:alarm_cleared, String.t()}

  @spec reduce(t(), operation()) :: t()
  def reduce(%__MODULE__{} = data, {:name_changed, name}) when is_binary(name) do
    %{data | name: name}
  end

  def reduce(%__MODULE__{} = data, {:internet_changed, internet}) when is_map(internet) do
    data |> Map.put(:internet, normalize_internet(internet)) |> apply_dependencies()
  end

  def reduce(%__MODULE__{} = data, {:tailnet_changed, tailnet}) when is_map(tailnet) do
    data |> Map.put(:tailnet, normalize_tailnet(tailnet)) |> apply_dependencies()
  end

  def reduce(%__MODULE__{} = data, {:cluster_changed, cluster}) when is_map(cluster) do
    data |> Map.put(:cluster, normalize_cluster(cluster)) |> apply_dependencies()
  end

  def reduce(%__MODULE__{} = data, {:alarm_set, %{id: id} = alarm}) when is_binary(id) do
    alarm = Map.take(alarm, [:id, :description, :level])

    alarms =
      data.alarms
      |> Enum.reject(&(&1.id == id))
      |> then(&[alarm | &1])
      |> Enum.sort_by(& &1.id)

    %{data | alarms: alarms}
  end

  def reduce(%__MODULE__{} = data, {:alarm_cleared, id}) when is_binary(id) do
    %{data | alarms: Enum.reject(data.alarms, &(&1.id == id))}
  end

  def reduce(%__MODULE__{} = data, _unknown_operation), do: data

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = data), do: Map.from_struct(data)

  defp normalize_internet(internet) do
    %{status: Map.get(internet, :status, :failed), reason: Map.get(internet, :reason)}
  end

  defp normalize_tailnet(tailnet) do
    observed = Map.get(tailnet, :observed_status, :offline)

    %{
      status: observed,
      observed_status: observed,
      authenticated: Map.get(tailnet, :authenticated, :unknown),
      hostname: Map.get(tailnet, :hostname),
      ipv4: Map.get(tailnet, :ipv4)
    }
  end

  defp normalize_cluster(cluster) do
    enabled = Map.get(cluster, :enabled, false)
    runtime = Map.get(cluster, :runtime_status, if(enabled, do: :failed, else: :disabled))

    %{
      status: runtime,
      runtime_status: runtime,
      enabled: enabled,
      node: Map.get(cluster, :node),
      connected: Map.get(cluster, :connected, [])
    }
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
end

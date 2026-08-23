defmodule NervesGate.DeviceState.Data do
  @moduledoc """
  Canonical, secret-free device state shared with all connected clients.

  The authoritative `NervesGate.DeviceState.Server` and every client replica
  keep the same `%Data{}`. All mutations go through the server first and are
  represented as operations. The server applies an operation and then
  broadcasts it, so every client applies the same pure transition in the same
  order while messages remain small.

  `apply_operation/2` has no direct side effects. It returns actions for the
  authoritative process to execute, including local notifications and runtime
  route application. Client replicas always discard actions.

  Boot identifiers, revisions, connection freshness, monitors, retries, and
  buffered messages are replication transport metadata and never belong to
  this structure. Credentials and other private runtime state are neither
  stored nor accepted by its operations.
  """

  alias NervesGate.Tailnet.Address

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
    subnet_router: %{
      status: :disabled,
      enabled: false,
      routes: [],
      advertised: [],
      approved: [],
      primary: [],
      error: nil
    },
    ssh: %{
      enabled: false,
      state: :disabled,
      address: nil,
      port: 22
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
  @type origin ::
          :bootstrap | :device | :internet | :tailnet | :subnet_router | :ssh | :cluster | :alarms

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

  @type subnet_router :: %{
          status: layer_status(),
          enabled: boolean(),
          routes: [String.t()],
          advertised: [String.t()],
          approved: [String.t()],
          primary: [String.t()],
          error: atom() | nil
        }

  @type ssh :: %{
          enabled: boolean(),
          state: :disabled | :waiting_for_tailnet | :listening | :error,
          address: :inet.ip4_address() | nil,
          port: 22
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
          subnet_router: subnet_router(),
          ssh: ssh(),
          cluster: cluster(),
          alarms: [alarm()]
        }

  @type operation ::
          {:set_name, origin(), String.t()}
          | {:set_internet, origin(), map()}
          | {:set_tailnet, origin(), map()}
          | {:set_subnet_router, origin(), map()}
          | {:configure_subnet_router, origin(), map()}
          | {:observe_subnet_router, origin(), map()}
          | {:fail_subnet_router, origin(), atom()}
          | {:set_ssh, origin(), map()}
          | {:configure_ssh, origin(), map()}
          | {:observe_ssh, origin(), map()}
          | {:set_cluster, origin(), map()}
          | {:set_alarm, origin(), map()}
          | {:clear_alarm, origin(), String.t()}

  @type action ::
          :broadcast
          | {:apply_subnet_router, boolean(), [String.t()]}
          | {:configure_ssh, boolean()}

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
        subnet_router: %{},
        ssh: %{},
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
      {:set_subnet_router, :bootstrap, options[:subnet_router]},
      {:set_ssh, :bootstrap, options[:ssh]},
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

  def apply_operation(%__MODULE__{} = data, {:set_subnet_router, :bootstrap, subnet_router})
      when is_map(subnet_router) do
    with {:ok, subnet_router} <- normalize_subnet_router(subnet_router) do
      data
      |> Map.put(:subnet_router, subnet_router)
      |> apply_dependencies()
      |> wrap_ok(:broadcast)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:configure_subnet_router, :subnet_router, desired})
      when is_map(desired) do
    with {:ok, desired} <- normalize_subnet_router_desired(desired) do
      data
      |> Map.update!(:subnet_router, &Map.merge(&1, desired))
      |> apply_dependencies()
      |> wrap_ok([:broadcast, {:apply_subnet_router, desired.enabled, desired.routes}])
    end
  end

  def apply_operation(%__MODULE__{} = data, {:observe_subnet_router, :subnet_router, observed})
      when is_map(observed) do
    with {:ok, observed} <- normalize_subnet_router_observed(observed) do
      data =
        data
        |> Map.update!(:subnet_router, &Map.merge(&1, observed))
        |> apply_dependencies()

      wrap_ok(data, [:broadcast | subnet_router_actions(data.subnet_router)])
    end
  end

  def apply_operation(%__MODULE__{} = data, {:fail_subnet_router, :subnet_router, reason})
      when is_atom(reason) and not is_nil(reason) do
    data
    |> Map.update!(:subnet_router, &Map.put(&1, :error, reason))
    |> apply_dependencies()
    |> wrap_ok(:broadcast)
  end

  def apply_operation(%__MODULE__{} = data, {:set_ssh, :bootstrap, ssh})
      when is_map(ssh) do
    with {:ok, ssh} <- normalize_ssh(ssh) do
      data
      |> Map.put(:ssh, ssh)
      |> apply_dependencies()
      |> wrap_ok(:broadcast)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:configure_ssh, :ssh, %{enabled: enabled} = desired})
      when map_size(desired) == 1 and is_boolean(enabled) do
    ssh =
      cond do
        not enabled -> %{enabled: false, state: :disabled, address: nil, port: 22}
        data.ssh.enabled -> data.ssh
        true -> %{enabled: true, state: :waiting_for_tailnet, address: nil, port: 22}
      end

    data
    |> Map.put(:ssh, ssh)
    |> apply_dependencies()
    |> wrap_ok([:broadcast, {:configure_ssh, enabled}])
  end

  def apply_operation(%__MODULE__{} = data, {:observe_ssh, :ssh, ssh}) when is_map(ssh) do
    with {:ok, ssh} <- normalize_ssh(ssh) do
      data
      |> Map.put(:ssh, ssh)
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

  defp normalize_subnet_router(subnet_router) do
    enabled = Map.get(subnet_router, :enabled, false)
    routes = Map.get(subnet_router, :routes, [])
    advertised = Map.get(subnet_router, :advertised, [])
    approved = Map.get(subnet_router, :approved, [])
    primary = Map.get(subnet_router, :primary, [])
    error = Map.get(subnet_router, :error)

    if only_keys?(subnet_router, [
         :enabled,
         :routes,
         :advertised,
         :approved,
         :primary,
         :error
       ]) and is_boolean(enabled) and routes?(routes) and routes?(advertised) and
         routes?(approved) and routes?(primary) and is_atom(error) do
      {:ok,
       %{
         status: subnet_router_status(enabled, routes, advertised, error),
         enabled: enabled,
         routes: routes,
         advertised: advertised,
         approved: approved,
         primary: primary,
         error: error
       }}
    else
      :error
    end
  end

  defp normalize_subnet_router_desired(desired) do
    enabled = Map.get(desired, :enabled)
    routes = Map.get(desired, :routes)

    if only_keys?(desired, [:enabled, :routes]) and is_boolean(enabled) and routes?(routes),
      do: {:ok, %{enabled: enabled, routes: routes}},
      else: :error
  end

  defp normalize_subnet_router_observed(observed) do
    advertised = Map.get(observed, :advertised, [])
    approved = Map.get(observed, :approved, [])
    primary = Map.get(observed, :primary, [])
    error = Map.get(observed, :error)

    if only_keys?(observed, [:advertised, :approved, :primary, :error]) and
         routes?(advertised) and routes?(approved) and routes?(primary) and is_atom(error) do
      {:ok, %{advertised: advertised, approved: approved, primary: primary, error: error}}
    else
      :error
    end
  end

  defp normalize_ssh(ssh) do
    enabled = Map.get(ssh, :enabled, false)
    state = Map.get(ssh, :state, if(enabled, do: :waiting_for_tailnet, else: :disabled))
    address = Map.get(ssh, :address)
    port = Map.get(ssh, :port, 22)

    if only_keys?(ssh, [:enabled, :state, :address, :port]) and
         valid_ssh?(enabled, state, address, port) do
      {:ok, %{enabled: enabled, state: state, address: address, port: port}}
    else
      :error
    end
  end

  defp valid_ssh?(false, :disabled, nil, 22), do: true

  defp valid_ssh?(true, state, nil, 22) when state in [:waiting_for_tailnet, :error],
    do: true

  defp valid_ssh?(true, :listening, address, 22), do: Address.ipv4?(address)
  defp valid_ssh?(_enabled, _state, _address, _port), do: false

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

    subnet_router_status =
      cond do
        not data.subnet_router.enabled ->
          :disabled

        tailnet_status != :online ->
          :blocked

        true ->
          subnet_router_status(
            true,
            data.subnet_router.routes,
            data.subnet_router.advertised,
            data.subnet_router.error
          )
      end

    ssh = apply_ssh_dependency(data.ssh, data.tailnet.observed_status)

    %{
      data
      | tailnet: Map.put(data.tailnet, :status, tailnet_status),
        subnet_router: Map.put(data.subnet_router, :status, subnet_router_status),
        ssh: ssh,
        cluster: Map.put(data.cluster, :status, cluster_status)
    }
  end

  defp apply_ssh_dependency(%{enabled: true} = ssh, observed_status)
       when observed_status != :online do
    %{ssh | state: :waiting_for_tailnet, address: nil}
  end

  defp apply_ssh_dependency(ssh, _observed_status), do: ssh

  defp apply_valid_operation!(operation, data) do
    {:ok, data, _actions} = apply_operation(data, operation)
    data
  end

  defp subnet_router_actions(%{enabled: false, advertised: [], error: nil}), do: []

  defp subnet_router_actions(%{enabled: false, advertised: []}), do: []

  defp subnet_router_actions(%{enabled: true, routes: routes, advertised: routes, error: nil}),
    do: []

  defp subnet_router_actions(subnet_router) do
    [{:apply_subnet_router, subnet_router.enabled, subnet_router.routes}]
  end

  defp subnet_router_status(false, _routes, _advertised, _error), do: :disabled
  defp subnet_router_status(true, _routes, _advertised, error) when not is_nil(error), do: :failed
  defp subnet_router_status(true, routes, routes, nil), do: :online
  defp subnet_router_status(true, _routes, _advertised, nil), do: :failed

  defp routes?(routes), do: is_list(routes) and Enum.all?(routes, &is_binary/1)

  defp wrap_ok(data, actions) when is_list(actions), do: {:ok, data, actions}
  defp wrap_ok(data, action), do: {:ok, data, [action]}
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp only_keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))
end

defmodule NervesGateQEMU.Harness do
  @moduledoc "Provisioning, convergence, and fault assertions for multi-gateway QEMU tests."

  alias NervesGateQEMU.{Commissioner, Environment, Fault, Gateway, Runner}

  @default_timeout 180_000

  @type cluster :: %{
          devices: [Runner.device()],
          ids: %{String.t() => String.t()},
          group: String.t()
        }

  @spec ensure_cluster!(keyword()) :: cluster()
  def ensure_cluster!(options \\ []) do
    count = Keyword.get(options, :count, 3)
    timeout = Keyword.get(options, :timeout, @default_timeout)
    group = Keyword.get(options, :group, Environment.cluster_group())
    devices = Runner.devices()

    if length(devices) < count do
      raise "integration topology needs at least #{count} gateways; run mix qemu setup --count #{count}"
    end

    devices = Enum.take(devices, count)
    ensure_ok!(Runner.start(:all), "start QEMU topology")
    ensure_ok!(Fault.heal_all(), "heal QEMU topology")
    await_gateways!(devices, "HTTP status endpoints", timeout, &match?({:ok, _status}, &1))

    commission_unconfigured!(devices, group)
    await_gateways!(devices, "Internet, Tailnet, and Cluster readiness", timeout, &ready_result/1)

    ids =
      Map.new(devices, fn device -> {device.id, device |> fetch!() |> Gateway.device_id()} end)

    cluster = %{devices: devices, ids: ids, group: group}
    await_mesh!(cluster, timeout)
    cluster
  end

  @spec restore!(cluster(), timeout()) :: cluster()
  def restore!(cluster, timeout \\ @default_timeout) do
    ensure_ok!(Runner.start(:all), "start QEMU topology")
    ensure_ok!(Fault.heal_all(), "heal QEMU topology")
    await_gateways!(cluster.devices, "gateway recovery", timeout, &ready_result/1)
    await_mesh!(cluster, timeout)
    cluster
  end

  @spec fetch!(Runner.device()) :: map()
  def fetch!(device) do
    case Gateway.fetch(device) do
      {:ok, status} -> status
      {:error, reason} -> raise "#{device.id} status unavailable: #{inspect(reason)}"
    end
  end

  @spec status(cluster(), String.t()) :: map()
  def status(cluster, id), do: cluster |> device!(id) |> fetch!()

  @spec device!(cluster(), String.t()) :: Runner.device()
  def device!(cluster, id) do
    Enum.find(cluster.devices, &(&1.id == String.upcase(id))) ||
      raise "unknown integration gateway #{id}"
  end

  @spec peers(cluster(), String.t()) :: [Runner.device()]
  def peers(cluster, id), do: Enum.reject(cluster.devices, &(&1.id == String.upcase(id)))

  @spec await!(String.t(), (-> term()), keyword()) :: term()
  def await!(description, operation, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    interval = Keyword.get(options, :interval, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(description, operation, deadline, interval, nil)
  end

  @spec await_ready!(cluster(), String.t(), timeout()) :: map()
  def await_ready!(cluster, id, timeout \\ @default_timeout) do
    device = device!(cluster, id)

    await!("#{id} readiness", fn -> ready_observation(device) end, timeout: timeout)
  end

  @spec await_mesh!(cluster(), timeout()) :: cluster()
  def await_mesh!(cluster, timeout \\ @default_timeout) do
    await!(
      "fully connected DeviceState mesh",
      fn ->
        observations = Map.new(cluster.devices, &{&1.id, Gateway.fetch(&1)})

        if mesh_ready?(cluster, observations) do
          {:ok, cluster}
        else
          {:retry, summarize_observations(observations)}
        end
      end,
      timeout: timeout
    )
  end

  @spec await_replica!(cluster(), String.t(), String.t(), boolean(), timeout()) :: map()
  def await_replica!(cluster, observer_id, subject_id, connected, timeout \\ @default_timeout) do
    observer = device!(cluster, observer_id)
    subject_device_id = Map.fetch!(cluster.ids, String.upcase(subject_id))

    await!(
      "#{observer_id} replica of #{subject_id} connected=#{connected}",
      fn -> replica_connection_observation(observer, subject_device_id, connected) end,
      timeout: timeout
    )
  end

  @spec await_replica_boot!(cluster(), String.t(), String.t(), String.t(), timeout()) :: map()
  def await_replica_boot!(
        cluster,
        observer_id,
        subject_id,
        boot_id,
        timeout \\ @default_timeout
      ) do
    observer = device!(cluster, observer_id)
    subject_device_id = Map.fetch!(cluster.ids, String.upcase(subject_id))

    await!(
      "#{observer_id} replica of #{subject_id} boot=#{boot_id}",
      fn -> replica_boot_observation(observer, subject_device_id, boot_id) end,
      timeout: timeout
    )
  end

  defp commission_unconfigured!(devices, group) do
    pending = Enum.reject(devices, fn device -> device |> fetch!() |> Gateway.configured?() end)

    if pending != [] do
      auth_key =
        case Environment.auth_key() do
          {:ok, value} -> value
          {:error, reason} -> raise "cannot commission QEMU gateways: #{inspect(reason)}"
        end

      Enum.each(pending, fn device ->
        Mix.shell().info("Commissioning #{device.id} through the backend command API…")
        Commissioner.commission(device, auth_key, group)
      end)
    end
  end

  defp await_gateways!(devices, description, timeout, predicate) do
    await!(
      description,
      fn -> gateway_observation(devices, predicate) end,
      timeout: timeout
    )
  end

  defp ready_result({:ok, status}), do: Gateway.ready?(status)
  defp ready_result({:error, _reason}), do: false

  defp ready_observation(device) do
    case Gateway.fetch(device) do
      {:ok, status} -> ready_status_observation(status)
      {:error, reason} -> {:retry, reason}
    end
  end

  defp ready_status_observation(status) do
    if Gateway.ready?(status), do: {:ok, status}, else: {:retry, Gateway.summary(status)}
  end

  defp replica_connection_observation(observer, subject_device_id, connected) do
    with {:ok, status} <- Gateway.fetch(observer),
         %{"connected" => ^connected} = replica <- Gateway.replica(status, subject_device_id) do
      {:ok, replica}
    else
      {:error, reason} -> {:retry, reason}
      replica -> {:retry, replica}
    end
  end

  defp replica_boot_observation(observer, subject_device_id, boot_id) do
    with {:ok, status} <- Gateway.fetch(observer),
         %{"connected" => true, "boot_id" => ^boot_id} = replica <-
           Gateway.replica(status, subject_device_id) do
      {:ok, replica}
    else
      {:error, reason} -> {:retry, reason}
      replica -> {:retry, replica}
    end
  end

  defp gateway_observation(devices, predicate) do
    observations = Map.new(devices, &{&1.id, Gateway.fetch(&1)})

    if Enum.all?(observations, fn {_id, result} -> predicate.(result) end),
      do: {:ok, observations},
      else: {:retry, summarize_observations(observations)}
  end

  defp mesh_ready?(cluster, observations) do
    expected_ids = Map.values(cluster.ids) |> MapSet.new()
    Enum.all?(observations, &observer_mesh_ready?(&1, cluster.ids, expected_ids))
  end

  defp observer_mesh_ready?({observer_id, {:ok, status}}, ids, expected_ids) do
    own_id = Map.fetch!(ids, observer_id)
    expected = MapSet.delete(expected_ids, own_id)
    replicas = Map.get(status, "replicas", %{})

    Gateway.ready?(status) and
      Enum.all?(expected, &match?(%{"connected" => true}, Map.get(replicas, &1)))
  end

  defp observer_mesh_ready?({_observer_id, {:error, _reason}}, _ids, _expected_ids), do: false

  defp summarize_observations(observations) do
    Map.new(observations, fn
      {id, {:ok, status}} -> {id, Gateway.summary(status)}
      {id, {:error, reason}} -> {id, %{error: reason}}
    end)
  end

  defp do_await(description, operation, deadline, interval, previous) do
    case operation.() do
      {:ok, value} ->
        value

      true ->
        :ok

      {:retry, observation} ->
        retry_or_raise(description, operation, deadline, interval, observation)

      false ->
        retry_or_raise(description, operation, deadline, interval, previous)

      observation ->
        retry_or_raise(description, operation, deadline, interval, observation)
    end
  end

  defp retry_or_raise(description, operation, deadline, interval, observation) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "Timed out waiting for #{description}; last observation: #{inspect(observation, pretty: true, limit: 50)}"
    else
      Process.sleep(interval)
      do_await(description, operation, deadline, interval, observation)
    end
  end

  defp ensure_ok!(:ok, _operation), do: :ok
  defp ensure_ok!({:ok, _value}, _operation), do: :ok

  defp ensure_ok!({:error, reason}, operation),
    do: raise("Failed to #{operation}: #{inspect(reason)}")
end

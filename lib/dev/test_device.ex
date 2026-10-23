defmodule Dev.TestDevice do
  @moduledoc """
  Common scenario access to a running Nerves Gate node.

  A target is a map with `:node`, an optional diagnostics `:dir`, and an optional
  `:fixture` tuple. These helpers neither boot devices nor configure networking.
  Calls are bounded and never retried. Fixture controls are host-only and explicit.
  """
  import ExUnit.Assertions

  def rpc(device, module, function, args \\ []),
    do: :erpc.call(device.node, module, function, args, 15_000)

  # Do not log commands or results: some public calls return private values.
  def call(device, function, args), do: rpc(device, NervesGate, function, args)

  def status(device) do
    status = :erpc.call(device.node, NervesGate, :status, [], 2_000)
    log(device, "snapshots.log", status)
    status
  catch
    :error, {:erpc, _} -> nil
  end

  def await(device, phase, predicate, timeout \\ 30_000) do
    if report = Process.get(:scenario_report), do: report.(phase)
    poll(device, phase, predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll(device, phase, predicate, deadline) do
    status = status(device)

    cond do
      status && predicate.(status) ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Timed out: #{phase}; diagnostics: #{Map.get(device, :dir, "not configured")}")

      true ->
        Process.sleep(500)
        poll(device, phase, predicate, deadline)
    end
  end

  def fixture_capabilities(%{fixture: {module, handle}}), do: module.capabilities(handle)
  def fixture_capabilities(_), do: []

  def control(device, operation, args \\ []) do
    if operation in fixture_capabilities(device) do
      {module, handle} = device.fixture
      module.control(handle, operation, args)
    else
      {:error, :unsupported_fixture_control}
    end
  end

  @doc "Hardware resources declared by device domains, regardless of current presence."
  def resources(status) do
    for {resource, supported} <- [
          ethernet: status.connections.ports != [],
          cellular: status.cellular.supported,
          can: bus?(status.buses, "can"),
          rs485: bus?(status.buses, "rs485")
        ],
        supported,
        do: resource
  end

  @doc "Fail when required, declared hardware is missing; link/enabled state is separate."
  def assert_present(status, required) do
    ethernet = if :ethernet in required, do: status.connections.ports, else: []

    buses =
      Enum.filter(status.buses.ports, fn port ->
        Map.get(%{"can" => :can, "rs485" => :rs485}, port.transport) in required
      end)

    missing = for port <- ethernet ++ buses, port.present != true, do: port.name

    missing =
      if :cellular in required and status.cellular.present != true,
        do: ["cellular modem" | missing],
        else: missing

    assert missing == [], "Expected hardware missing or unobserved: #{Enum.join(missing, ", ")}"
    :ok
  end

  defp bus?(%{available: true, ports: ports}, transport),
    do: Enum.any?(ports, &(&1.transport == transport))

  defp bus?(_, _), do: false

  defp log(device, file, value) do
    if dir = device[:dir] do
      File.write!(
        Path.join(dir, file),
        "#{System.system_time(:millisecond)} #{inspect(value, limit: :infinity)}\n",
        [:append]
      )
    end
  end
end

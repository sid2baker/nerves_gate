defmodule NervesGate.Buses.Policy do
  @moduledoc "Fixed EC100 ports and bounded, explicit bus operations. No arbitrary paths or writes."

  @can ["can0", "can1"]
  @serial ["ttyS3", "ttyS4"]
  @bitrates [10_000, 20_000, 50_000, 100_000, 125_000, 250_000, 500_000, 1_000_000]

  def ports, do: @can ++ @serial
  def bitrates, do: @bitrates

  def configure(port, %{"enabled" => enabled} = params) when port in @can do
    with {:ok, enabled} <- boolean(enabled),
         {:ok, bitrate} <- integer(params["bitrate"]),
         {:ok, listen_only} <- boolean(Map.get(params, "listen_only", true)),
         true <- bitrate in @bitrates do
      {:ok, %{enabled: enabled, bitrate: bitrate, listen_only: listen_only}}
    else
      _ -> {:error, :bus_parameters}
    end
  end

  def configure(port, %{"enabled" => enabled}) when port in @serial do
    with {:ok, enabled} <- boolean(enabled), do: {:ok, %{enabled: enabled}}
  end

  def configure(_, _), do: {:error, :bus_parameters}

  def modbus(port, %{"authorized" => authorized} = params) when port in @serial do
    with {:ok, true} <- boolean(authorized),
         {:ok, unit} <- integer(params["unit"]),
         {:ok, function} <- integer(params["function"]),
         {:ok, address} <- integer(params["address"]),
         {:ok, count} <- integer(params["count"]),
         true <- unit in 1..247 and function in [3, 4],
         true <- address in 0..65_535 and count in 1..32 and address + count <= 65_536 do
      {:ok, %{unit: unit, function: function, address: address, count: count}}
    else
      _ -> {:error, :modbus_parameters}
    end
  end

  def modbus(_, _), do: {:error, :modbus_parameters}

  def available(%{available: false}), do: {:error, :bus_unsupported}

  def available(%{operation: operation}) when not is_nil(operation),
    do: {:error, :operation_in_progress}

  def available(_), do: :ok

  def port(status, name) do
    with :ok <- available(status),
         %{present: true} = port <- Enum.find(status.ports, &(&1.name == name)) do
      {:ok, port}
    else
      {:error, _} = error -> error
      _ -> {:error, :bus_missing}
    end
  end

  def capture(%{enabled: false}), do: {:error, :bus_disabled}

  def capture(%{transport: "can", listen_only: mode}) when mode != true,
    do: {:error, :can_not_passive}

  def capture(_), do: :ok

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :bus_parameters}
    end
  end

  defp integer(_), do: {:error, :bus_parameters}

  defp boolean(value) when value in [true, "true"], do: {:ok, true}
  defp boolean(value) when value in [false, "false"], do: {:ok, false}
  defp boolean(_), do: {:error, :bus_parameters}
end

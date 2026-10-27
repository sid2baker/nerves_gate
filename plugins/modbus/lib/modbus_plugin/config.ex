defmodule ModbusPlugin.Config do
  @moduledoc "Bounded, volatile read-only TCP/RTU configuration. Addresses are zero-based."

  def validate(id, params) when is_binary(id) and is_map(params) do
    host = params["host"]

    config = %{
      id: id,
      transport: params["transport"] || "tcp",
      serial_port: params["serial_port"],
      authorized: params["authorized"] in [true, "true"],
      host: host,
      port: integer(params["port"]),
      unit: integer(params["unit"]),
      table: table(params["table"]),
      address: integer(params["address"]),
      count: integer(params["count"]),
      interval: integer(params["interval"]),
      timeout: integer(params["timeout"])
    }

    if Regex.match?(~r/\A[a-zA-Z0-9_-]{1,32}\z/, id) and
         valid_transport?(config) and config.unit in 1..247 and
         config.table in [:holding, :input] and config.address in 0..65535 and
         config.count in 1..125 and config.address + config.count <= 65536 and
         config.interval in 100..60_000 and config.timeout in 100..5_000 do
      {:ok, config}
    else
      {:error, :invalid_configuration}
    end
  end

  def validate(_, _), do: {:error, :invalid_configuration}

  defp valid_transport?(%{transport: "tcp", host: host, port: port}),
    do:
      is_binary(host) and byte_size(host) in 1..253 and
        Regex.match?(~r/\A[a-zA-Z0-9.:%_-]+\z/, host) and port in 1..65535

  defp valid_transport?(%{transport: "rtu", serial_port: port, authorized: true}),
    do: port in ["ttyS3", "ttyS4"]

  defp valid_transport?(_), do: false
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp table("holding"), do: :holding
  defp table("input"), do: :input
  defp table(_), do: nil
end

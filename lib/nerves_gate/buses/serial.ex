defmodule NervesGate.Buses.Serial do
  @moduledoc "Short-lived passive UART sessions. EC100's qualified automatic-direction 9600 8N1 profile."
  alias Circuits.UART
  alias NervesGate.Buses.Modbus

  @options [
    speed: 9600,
    data_bits: 8,
    stop_bits: 1,
    parity: :none,
    flow_control: :none,
    active: false
  ]

  # Called only with allowlisted paths by EC100. Accepting a path here also permits isolated PTY tests.
  def run(path, operation, params) do
    with {:ok, uart} <- UART.start_link() do
      try do
        with :ok <- UART.open(uart, path, @options) do
          execute(uart, operation, params)
        end
      after
        UART.stop(uart)
      end
    end
  end

  defp execute(uart, :capture, _) do
    deadline = now() + 5_000
    capture(uart, <<>>, deadline)
  end

  defp execute(uart, :modbus_read, params) do
    # Refuse an already-active bus. This is NOT arbitration: another master may start later.
    # Never retry, scan units, or send a broadcast/write function.
    with :ok <- UART.flush(uart, :receive),
         {:ok, ""} <- UART.read(uart, 50),
         :ok <- UART.write(uart, Modbus.request(params), 500) do
      receive_response(uart, <<>>, params, now() + 1_000)
    else
      {:ok, _traffic} -> {:error, :serial_busy}
      error -> error
    end
  end

  defp capture(uart, data, deadline) do
    if byte_size(data) >= 4_096 or now() >= deadline do
      {:ok, %{hex: Base.encode16(data), bytes: byte_size(data)}}
    else
      case UART.read(uart, max(1, deadline - now())) do
        {:ok, chunk} ->
          remaining = min(byte_size(chunk), 4_096 - byte_size(data))
          capture(uart, data <> binary_part(chunk, 0, remaining), deadline)

        error ->
          error
      end
    end
  end

  defp receive_response(uart, data, params, deadline) do
    cond do
      byte_size(data) > 512 ->
        {:error, :modbus_response}

      Modbus.complete?(data, params) ->
        with {:ok, registers} <- Modbus.response(data, params) do
          {:ok, Map.put(params, :registers, registers)}
        end

      now() >= deadline ->
        {:error, :modbus_timeout}

      true ->
        case UART.read(uart, max(1, deadline - now())) do
          {:ok, chunk} -> receive_response(uart, data <> chunk, params, deadline)
          error -> error
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

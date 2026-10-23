defmodule NervesGate.Network.EG800AK do
  @moduledoc """
  EC100's Quectel ECM driver: configure PAP, activate the packet context, then
  connect the USB network adapter. Runs inside VintageNetECM's AT controller,
  over its already-open UART.
  """
  @behaviour VintageNetECM.Modem

  alias NervesGate.Network.CellularAuthentication
  alias VintageNetECM.AT
  alias VintageNetECM.Modem.Quectel

  @impl true
  def activate_data_call(uart, context_id) do
    with {:ok, lines} <- AT.command(uart, "AT+QIACT?", timeout: 2_000),
         :ok <- prepare_context(uart, context_id, packet_active?(lines, context_id)),
         {:ok, _} <- AT.command(uart, "AT+QNETDEVCTL=1,#{context_id}", timeout: 8_000) do
      :ok
    end
  end

  defp prepare_context(_, _, true), do: :ok

  defp prepare_context(uart, context_id, false) do
    with :ok <- configure_authentication(uart, context_id),
         {:ok, _} <- AT.command(uart, "AT+QIACT=#{context_id}", timeout: 15_000) do
      :ok
    end
  end

  defp configure_authentication(uart, context_id) do
    with {:ok, record} <- CellularAuthentication.load(),
         response = AT.command(uart, "AT+CGDCONT?", timeout: 2_000),
         {:ok, command} <- CellularAuthentication.command(record, response, context_id),
         {:ok, _} <- AT.command(uart, command, timeout: 5_000) do
      :ok
    else
      _ -> {:error, :cellular_authentication_failed}
    end
  catch
    # Exceptions and dependency errors may include the credential-bearing command.
    _, _ -> {:error, :cellular_authentication_failed}
  end

  @impl true
  def deactivate_data_call(uart, context_id) do
    _ = AT.command(uart, "AT+QNETDEVCTL=0,#{context_id}", timeout: 5_000)
    # Release this context before the next controller configures its APN/PAP.
    # Never touch the network's separate IMS context.
    _ = AT.command(uart, "AT+QIDEACT=#{context_id}", timeout: 8_000)
    :ok
  end

  @impl true
  def data_call_active?(uart) do
    case AT.command(uart, "AT+QNETDEVCTL?", timeout: 2_000) do
      {:ok, lines} -> parse_data_call_active(lines)
      _ -> false
    end
  end

  @doc false
  def parse_data_call_active(lines) do
    # Four fields: connect type, context ID, URC switch, PDN status.
    # A manual/automatic connect setting alone does not mean the PDN is up.
    Enum.any?(lines, &Regex.match?(~r/\A\+QNETDEVCTL:\s*[13],\s*[1-8],\s*[01],\s*1\s*\z/, &1))
  end

  @doc false
  def packet_active?(lines, context_id) when context_id in 1..8 do
    Enum.any?(
      lines,
      &Regex.match?(~r/\A\+QIACT:\s*#{context_id},\s*1,\s*[13],"[^"\r\n]+"\s*\z/, &1)
    )
  end

  @impl true
  defdelegate access_technology(uart), to: Quectel
  @impl true
  defdelegate default_at_tty(), to: Quectel
  @impl true
  defdelegate iccid(uart), to: Quectel
  @impl true
  defdelegate network_info(uart), to: Quectel
  @impl true
  defdelegate network_time(uart), to: Quectel
end

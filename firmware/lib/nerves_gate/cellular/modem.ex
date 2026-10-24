defmodule NervesGate.Cellular.Modem do
  @moduledoc """
  EC100's Quectel ECM driver: configure PAP, activate the packet context, then
  connect the USB network adapter. Runs inside VintageNetECM's AT controller,
  over its already-open UART.
  """
  @behaviour VintageNetECM.Modem

  alias NervesGate.Cellular.{Authentication, Profile}
  alias VintageNetECM.AT
  alias VintageNetECM.Modem.Quectel

  @doc false
  def initialize(name, level) do
    with {:ok, commands} <- hotplug_commands(command(name, "AT+QSIMDET?"), level) do
      configure_hotplug(name, commands)
    end
  end

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
    with {:ok, record} <- Authentication.load(),
         response = AT.command(uart, "AT+CGDCONT?", timeout: 2_000),
         {:ok, command} <- Authentication.command(record, response, context_id),
         {:ok, _} <- AT.command(uart, command, timeout: 5_000) do
      :ok
    else
      _ ->
        {:error,
         %{
           code: "cellular_authentication_failed",
           message:
             "The modem's data context or authentication could not be configured. No data-call activation was attempted."
         }}
    end
  catch
    # Exceptions and dependency errors may include the credential-bearing command.
    _, _ ->
      {:error,
       %{
         code: "cellular_authentication_failed",
         message:
           "The modem's data context or authentication could not be configured. No data-call activation was attempted."
       }}
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

  def controller do
    case Profile.get() do
      %{interface: name, sim_detect_level: level} when level in [0, 1] ->
        GenServer.whereis(
          {:via, Registry, {VintageNet.Interface.Registry, {VintageNetECM.ATController, name}}}
        )

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def hotplug_commands({:ok, lines}, level) when level in [0, 1] do
    setting =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/\A\+QSIMDET:\s*([01]),\s*([01])(?:,"SIM1")?\s*\z/, line) do
          [_, enabled, active] -> {enabled, active}
          _ -> nil
        end
      end)

    expected = {"1", Integer.to_string(level)}

    case setting do
      ^expected ->
        {:ok, []}

      {_, _} ->
        # Applying the detect level needs one SIM/radio reinitialization, not a
        # gateway reboot. Never reset an already-correct modem on each refresh.
        {:ok, ["AT+QSIMDET=1,#{level}", "AT+CFUN=0", "AT+CFUN=1"]}

      nil ->
        {:error,
         %{
           code: "cellular_setup_failed",
           message:
             "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
         }}
    end
  end

  def hotplug_commands(_, _),
    do:
      {:error,
       %{
         code: "cellular_setup_failed",
         message:
           "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
       }}

  defp configure_hotplug(name, commands) do
    Enum.reduce_while(commands, :ok, fn cmd, :ok ->
      case command(name, cmd, 10_000) do
        {:ok, _} ->
          {:cont, :ok}

        _ ->
          {:halt,
           {:error,
            %{
              code: "cellular_setup_failed",
              message:
                "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
            }}}
      end
    end)
  end

  def command(name, cmd, timeout \\ 2_000),
    do: VintageNetECM.command(name, cmd, timeout: timeout)
end

defmodule NervesGate.Cellular.Modem do
  @moduledoc """
  EC100's Quectel ECM driver: configure PAP, activate the packet context, then
  connect the USB network adapter. Runs inside VintageNetECM's AT controller,
  over its already-open UART.
  """
  @behaviour VintageNetECM.Modem

  alias NervesGate.Cellular.{Authentication, Profile, Providers, SIM}
  alias VintageNetECM.AT
  alias VintageNetECM.Modem.Quectel

  @doc false
  def initialize(name, level) do
    case detection_status(name) do
      {:error, reason} when reason in [:timeout, :not_running, :tty_not_open, :starting] ->
        {:error,
         %{
           code: "cellular_controller_starting",
           message: "Waiting for the modem to start. No SIM setting or PIN was sent."
         }}

      response ->
        with {:ok, commands} <- hotplug_commands(response, level),
             do: configure_hotplug(name, commands)
    end
  end

  defp detection_status(name) do
    command(name, "AT+QSIMDET?")
  catch
    :exit, _ -> {:error, :starting}
  end

  @impl true
  def activate_data_call(uart, context_id) do
    config = current_configuration()

    case connection_mode(config) do
      :setup_only ->
        :ok

      {:data, apn} ->
        connect(uart, context_id, apn, get_in(config, [:vintage_net_ecm, :carrier_profile]))

      :unsupported ->
        {:error, :unqualified_cellular_configuration}
    end
  end

  defp connect(uart, context_id, apn, provider_id) do
    with :ready <- SIM.sim_state(AT.command(uart, "AT+CPIN?", timeout: 2_000)),
         {:ok, lines} <- AT.command(uart, "AT+QIACT?", timeout: 2_000),
         :ok <- release_context(uart, context_id, packet_active?(lines, context_id)),
         :ok <- configure_authentication(uart, context_id, apn, provider_id),
         {:ok, _} <- AT.command(uart, "AT+QIACT=#{context_id}", timeout: 15_000),
         {:ok, _} <- AT.command(uart, "AT+QNETDEVCTL=1,#{context_id}", timeout: 8_000) do
      :ok
    else
      state when is_atom(state) -> {:error, :sim_not_ready}
      error -> error
    end
  end

  defp release_context(_, _, false), do: :ok

  defp release_context(uart, context_id, true) do
    # A live context can retain a previous APN/password. Never assume it matches
    # this connection attempt, and never deactivate the separate IMS context.
    with {:ok, _} <- AT.command(uart, "AT+QNETDEVCTL=0,#{context_id}", timeout: 5_000),
         {:ok, _} <- AT.command(uart, "AT+QIDEACT=#{context_id}", timeout: 8_000),
         do: :ok
  end

  defp configure_authentication(uart, context_id, requested_apn, provider_id) do
    with {:ok, private} <- Authentication.load(),
         %{error: nil} = settings <-
           Providers.read(&AT.command(uart, &1, timeout: 2_000), requested_apn, provider_id),
         record = authentication(private, settings),
         {:ok, _} <-
           AT.command(uart, ~s(AT+CGDCONT=#{context_id},"IP","#{settings.apn}"), timeout: 5_000),
         response = AT.command(uart, "AT+CGDCONT?", timeout: 2_000),
         {:ok, command} <- Authentication.command(record, response, context_id, settings.apn),
         {:ok, _} <- AT.command(uart, command, timeout: 5_000) do
      :ok
    else
      _ -> authentication_error()
    end
  catch
    # Dependency errors can contain the credential-bearing AT command.
    _, _ -> authentication_error()
  end

  defp authentication(%{apn: apn} = private, %{apn: apn}), do: private
  defp authentication(_, settings), do: settings.credentials

  defp authentication_error do
    {:error,
     %{
       code: "cellular_authentication_failed",
       message:
         "The modem's data context or authentication could not be configured. No data-call activation was attempted."
     }}
  end

  @doc false
  def connection_mode(%{
        type: VintageNetECM,
        vintage_net_ecm: %{modem: __MODULE__, setup_only: true}
      }),
      do: :setup_only

  def connection_mode(%{
        type: VintageNetECM,
        vintage_net_ecm: %{modem: __MODULE__, service_providers: [%{apn: apn} | _]}
      })
      when is_binary(apn), do: {:data, apn}

  def connection_mode(_), do: :unsupported

  defp current_configuration do
    case Profile.get() do
      %{interface: name} -> VintageNet.get_configuration(name)
      _ -> nil
    end
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
    case connection_mode(current_configuration()) do
      # The controller has no bearer to maintain in SIM-setup mode. This is an
      # internal scheduling answer, never an Internet-connectivity observation.
      :setup_only ->
        true

      {:data, _} ->
        case AT.command(uart, "AT+QNETDEVCTL?", timeout: 2_000) do
          {:ok, lines} -> parse_data_call_active(lines)
          _ -> false
        end

      :unsupported ->
        false
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

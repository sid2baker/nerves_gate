defmodule NervesGate.Cellular.Modem do
  @moduledoc """
  EC100's Quectel ECM driver: configure PAP, activate the packet context, then
  connect the USB network adapter. Modem callbacks run in exclusive AT sessions
  on VintageNetECM's supervised channel, shared with management commands and SMS.
  """
  @behaviour VintageNetECM.Modem

  alias NervesGate.Cellular.{Authentication, Profile, Providers, SIM}
  alias VintageNetECM.AT
  alias VintageNetECM.Modem.Quectel

  @doc false
  def initialize(name, level) do
    result =
      VintageNetECM.session(
        name,
        fn at ->
          with {:ok, _} = response <- AT.command(at, "AT+QSIMDET?", timeout: 2_000),
               {:ok, commands} <- hotplug_commands(response, level),
               do: configure_hotplug(at, commands)
        end,
        timeout: 35_000
      )

    case result do
      {:error, reason}
      when reason in [:timeout, :not_running, :tty_not_open, :not_ready, :busy] ->
        {:error,
         %{
           code: "cellular_controller_starting",
           message: "Waiting for the modem to start. No SIM setting or PIN was sent."
         }}

      {:error, :desynchronized} ->
        {:error,
         %{
           code: "cellular_channel_desynchronized",
           message:
             "The modem AT channel needs explicit recovery. No SIM setting or PIN was sent."
         }}

      :ok ->
        :ok

      {:error, %{}} = result ->
        result

      _ ->
        hotplug_error()
    end
  end

  @impl true
  def activate_data_call(at, context_id) do
    config = current_configuration()

    case connection_mode(config) do
      :setup_only ->
        :ok

      {:data, apn} ->
        connect(at, context_id, apn, get_in(config, [:vintage_net_ecm, :carrier_profile]))

      :unsupported ->
        {:error, :unqualified_cellular_configuration}
    end
  end

  defp connect(at, context_id, apn, provider_id) do
    with :ready <- SIM.sim_state(AT.command(at, "AT+CPIN?", timeout: 2_000)),
         {:ok, lines} <- AT.command(at, "AT+QIACT?", timeout: 2_000),
         :ok <- release_context(at, context_id, packet_active?(lines, context_id)),
         :ok <- configure_authentication(at, context_id, apn, provider_id),
         {:ok, _} <- AT.command(at, "AT+QIACT=#{context_id}", timeout: 15_000),
         {:ok, _} <- AT.command(at, "AT+QNETDEVCTL=1,#{context_id}", timeout: 8_000) do
      :ok
    else
      state when is_atom(state) -> {:error, :sim_not_ready}
      error -> error
    end
  end

  defp release_context(_, _, false), do: :ok

  defp release_context(at, context_id, true) do
    # A live context can retain a previous APN/password. Never assume it matches
    # this connection attempt, and never deactivate the separate IMS context.
    with {:ok, _} <- AT.command(at, "AT+QNETDEVCTL=0,#{context_id}", timeout: 5_000),
         {:ok, _} <- AT.command(at, "AT+QIDEACT=#{context_id}", timeout: 8_000),
         do: :ok
  end

  defp configure_authentication(at, context_id, requested_apn, provider_id) do
    with {:ok, private} <- Authentication.load(),
         %{error: nil} = settings <-
           Providers.read(&AT.command(at, &1, timeout: 2_000), requested_apn, provider_id),
         record = authentication(private, settings),
         {:ok, _} <-
           AT.command(at, ~s(AT+CGDCONT=#{context_id},"IP","#{settings.apn}"), timeout: 5_000),
         response = AT.command(at, "AT+CGDCONT?", timeout: 2_000),
         {:ok, command} <- Authentication.command(record, response, context_id, settings.apn),
         {:ok, _} <- AT.command(at, command, timeout: 5_000) do
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
  def deactivate_data_call(at, context_id) do
    _ = AT.command(at, "AT+QNETDEVCTL=0,#{context_id}", timeout: 5_000)
    # Release this context before the next controller configures its APN/PAP.
    # Never touch the network's separate IMS context.
    _ = AT.command(at, "AT+QIDEACT=#{context_id}", timeout: 8_000)
    :ok
  end

  @impl true
  def data_call_active?(at) do
    case connection_mode(current_configuration()) do
      # The controller has no bearer to maintain in SIM-setup mode. This is an
      # internal scheduling answer, never an Internet-connectivity observation.
      :setup_only ->
        true

      {:data, _} ->
        at |> AT.command("AT+QNETDEVCTL?", timeout: 2_000) |> parse_data_call_active()

      :unsupported ->
        false
    end
  end

  @doc false
  def parse_data_call_active({:ok, lines}) do
    # Four fields: connect type, context ID, URC switch, PDN status.
    # A manual/automatic connect setting alone does not mean the PDN is up.
    Enum.any?(lines, &Regex.match?(~r/\A\+QNETDEVCTL:\s*[13],\s*[1-8],\s*[01],\s*1\s*\z/, &1))
  end

  def parse_data_call_active({:error, :error}), do: false
  def parse_data_call_active({:error, {kind, _}}) when kind in [:cme, :cms], do: false

  # An unknown result is not evidence that a working call dropped.
  # Leave it alone; the channel fences uncertain exchanges.
  def parse_data_call_active({:error, _}), do: true

  @doc false
  def packet_active?(lines, context_id) when context_id in 1..8 do
    Enum.any?(
      lines,
      &Regex.match?(~r/\A\+QIACT:\s*#{context_id},\s*1,\s*[13],"[^"\r\n]+"\s*\z/, &1)
    )
  end

  @impl true
  defdelegate access_technology(at), to: Quectel
  @impl true
  defdelegate default_at_tty(), to: Quectel
  @impl true
  defdelegate iccid(at), to: Quectel
  @impl true
  defdelegate network_info(at), to: Quectel
  @impl true
  defdelegate network_time(at), to: Quectel

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
        hotplug_error()
    end
  end

  def hotplug_commands(_, _), do: hotplug_error()

  defp hotplug_error do
    {:error,
     %{
       code: "cellular_setup_failed",
       message:
         "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
     }}
  end

  defp configure_hotplug(at, commands) do
    Enum.reduce_while(commands, :ok, fn cmd, :ok ->
      case AT.command(at, cmd, timeout: 10_000) do
        {:ok, _} ->
          {:cont, :ok}

        _ ->
          {:halt, hotplug_error()}
      end
    end)
  end

  @doc "Submit one encoded PDU in a managed AT session; never retry an unknown outcome."
  def submit_sms(name, pdu, tpdu_length)
      when is_binary(pdu) and tpdu_length in 1..255 and
             byte_size(pdu) == 2 * (tpdu_length + 1) do
    case Base.decode16(pdu) do
      {:ok, <<0, _::binary>>} ->
        VintageNetECM.session(name, &submit_in_pdu_mode(&1, pdu, tpdu_length), timeout: 130_000)

      _ ->
        {:error, :invalid_sms_pdu}
    end
  rescue
    # Dependency exceptions may contain payloads or unsolicited subscriber data.
    _ -> {:error, :outcome_unknown}
  end

  def submit_sms(_, _, _), do: {:error, :invalid_sms_pdu}

  defp submit_in_pdu_mode(at, pdu, length) do
    case AT.command(at, "AT+CMGF?") do
      {:ok, ["+CMGF: 0"]} -> submit_pdu(at, pdu, length)
      _ -> {:error, :sms_pdu_mode_required}
    end
  end

  defp submit_pdu(at, pdu, length) do
    with :ok <- AT.send(at, "AT+CMGS=#{length}\r"),
         {:ok, {:intermediate, "> "}} <- AT.receive(at),
         :ok <- AT.send(at, pdu <> <<26>>),
         {:ok, {:response, ["+CMGS: " <> reference, "OK"]}} <-
           AT.receive(at, timeout: 120_000) do
      if Regex.match?(~r/\A[0-9]{1,3}\z/, reference),
        do: :ok,
        else: {:error, :outcome_unknown}
    else
      {:ok, {:response, lines}} ->
        final = List.last(lines)

        if final == "ERROR" or String.starts_with?(final, ["+CMS ERROR:", "+CME ERROR:"]),
          do: {:error, :sms_rejected},
          else: {:error, :outcome_unknown}

      _ ->
        {:error, :outcome_unknown}
    end
  end

  def command(name, cmd, timeout \\ 2_000),
    do: VintageNetECM.command(name, cmd, timeout: timeout)
end

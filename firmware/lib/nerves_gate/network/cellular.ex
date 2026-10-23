defmodule NervesGate.Network.Cellular do
  @moduledoc """
  Firmware modem profile, sanitized SIM observations and bounded commissioning.

  VintageNetECM remains the only AT-port owner. PIN commands go through its
  serialized command API, once only. A private SIM-bound PIN store supports
  automatic unlock after restart; no credential or SIM identifier is published.

  `:nerves_gate, :cellular` is nil on platforms without a modem profile. A profile
  contains `:interface` and a standard VintageNet `:config` (ECM, QMI or Mobile).
  EC100 uses the Quectel EG800AK's ECM data path. Power/reset and stable interface
  naming belong to the BSP. Never use the recovery gadget's usb0.
  """
  alias NervesGate.Config
  alias NervesGate.Network.CellularPIN

  def profile do
    case Application.get_env(:nerves_gate, :cellular) do
      %{interface: name, config: %{type: type} = config} = profile
      when is_binary(name) and is_atom(type) ->
        if Regex.match?(~r/\A(?:wwan|ppp|cell)[0-9]+\z/, name) and
             technology_key(config) != nil and Code.ensure_loaded?(type),
           do: profile

      _ ->
        nil
    end
  end

  def configurations(network) do
    case {profile(), Config.cellular?(network)} do
      {nil, true} ->
        {:error, :cellular_unsupported}

      {nil, false} ->
        {:ok, []}

      {%{interface: name}, false} ->
        {:ok, [{name, %{type: VintageNet.Technology.Null}}]}

      {%{interface: name, config: config}, true} ->
        key = technology_key(config)

        options =
          Map.put(config[key], :service_providers, [%{apn: Config.internet(network)["apn"]}])

        {:ok, [{name, Map.put(config, key, options)}]}
    end
  end

  @doc false
  def empty do
    %{
      sim: :unknown,
      pin_saved: nil,
      auto_unlock: :unknown,
      pin_lock: :unknown,
      pin_attempts_remaining: nil,
      registration: :unknown,
      operator: nil,
      signal_dbm: nil,
      refreshed_at: nil,
      operation: nil,
      error: nil
    }
  end

  @doc false
  def view(nil) do
    Map.merge(empty(), %{supported: false, enabled: false, present: nil})
  end

  def view(status) do
    observed = status.observed || %{}
    supported = Map.get(observed, :cellular_supported, false)
    network = NervesGate.Observations.Network.settings(status)
    enabled = supported and Config.cellular?(network)
    present = get_in(observed, [:cellular, :present])
    cached = Map.get(status, :cellular) || empty()

    data =
      if enabled and present do
        cached
      else
        reset(cached)
      end

    Map.merge(data, %{supported: supported, enabled: enabled, present: present})
  end

  @doc false
  def available(status, operation \\ :refresh) do
    cellular = view(status)

    cond do
      not cellular.supported -> {:error, :cellular_unsupported}
      status.recovering -> {:error, :recovery_in_progress}
      status.trial != nil -> {:error, :trial_in_progress}
      status.phase != :idle -> {:error, :operation_in_progress}
      true -> modem_available(cellular, operation)
    end
  end

  defp modem_available(_, :forget_pin), do: :ok
  defp modem_available(%{enabled: false}, _), do: {:error, :cellular_disabled}
  defp modem_available(%{present: true}, _), do: :ok
  defp modem_available(_, _), do: {:error, :cellular_missing}

  @doc false
  def parameters(:refresh, []), do: :ok
  def parameters(:forget_pin, []), do: :ok
  def parameters(:save_pin, [pin]), do: valid_pins([pin])
  def parameters(:unlock, [pin]), do: valid_pins([pin])
  def parameters(:change_pin, [current, new]), do: valid_pins([current, new])
  def parameters(:set_pin_lock, [enabled, pin]) when is_boolean(enabled), do: valid_pins([pin])
  def parameters(_, _), do: {:error, :cellular_parameters}

  defp valid_pins(pins) do
    if Enum.all?(pins, &(is_binary(&1) and Regex.match?(~r/\A[0-9]{4,8}\z/, &1))),
      do: :ok,
      else: {:error, :cellular_parameters}
  end

  # OTP crash reports from the dependency can contain its last AT command.
  # Filter before any logger handler (including persistent RingLogger) sees it.
  @doc false
  def filter_log(event, _) do
    redact(event)
  catch
    # Unknown log shapes must not disable the primary filter or leak credentials.
    _, _ -> :stop
  end

  defp redact({:cellular, operation, _}), do: {:cellular, operation, :redacted}

  defp redact({module, function, args})
       when module in [__MODULE__, CellularPIN] and is_list(args),
       do: {module, function, :redacted}

  defp redact(value) when is_binary(value) do
    cond do
      Regex.match?(~r/AT\+(?:CPIN|CPWD|CLCK)=/, value) -> "[REDACTED SIM COMMAND]"
      Regex.match?(~r/\+QCCID:\s*[0-9]/, value) -> "[REDACTED SIM ID]"
      true -> value
    end
  end

  defp redact(value) when is_list(value) do
    if value != [] and List.ascii_printable?(value),
      do: value |> List.to_string() |> redact() |> String.to_charlist(),
      else: Enum.map(value, &redact/1)
  end

  defp redact({key, value}) when is_atom(key) or is_binary(key) do
    if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(value)}
  end

  defp redact(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  defp redact(value) when is_map(value) do
    value |> Map.to_list() |> Map.new(&redact/1)
  end

  defp redact(value), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()
    String.contains?(key, "pin") or key in ["fingerprint", "identity", "iccid", "imsi", "imei"]
  end

  # Deliberately contain every worker exception here: dependency exception terms
  # and Task crash reports can include credential-bearing command arguments.
  @doc false
  def perform(operation, params) do
    with :ok <- parameters(operation, params),
         %{interface: name, config: %{type: VintageNetECM}} <- profile() do
      execute(name, operation, params)
    else
      {:error, _} = error -> error
      _ -> {:error, :cellular_unsupported}
    end
  catch
    _, _ -> {:error, :cellular_outcome_unknown}
  end

  @doc false
  def cached, do: Map.merge(empty(), CellularPIN.metadata())

  @doc false
  def reset(data) do
    cached = Map.take(data, [:pin_saved, :auto_unlock, :operation, :error])

    cached =
      if cached[:auto_unlock] in [:ready, :different_sim],
        do: Map.put(cached, :auto_unlock, :identity_unknown),
        else: cached

    Map.merge(empty(), cached)
  end

  # This is internal admission only, never an accepted public operation name.
  # Like perform/2, its catch-all boundary keeps secret arguments out of Task logs.
  @doc false
  def auto_unlock do
    with %{interface: name, config: %{type: VintageNetECM}} <- profile(),
         :pin_required <- sim_state(command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         {:ok, pin} <- CellularPIN.consume(identity),
         :ok <- unlock_and_save(name, pin, identity),
         :ok <- resume(name) do
      read_result(name)
    else
      {:error, _} = error -> error
      _ -> {:error, :cellular_auto_unlock_blocked}
    end
  catch
    _, _ -> {:error, :cellular_outcome_unknown}
  end

  defp execute(name, :refresh, []), do: read_result(name)

  defp execute(_, :forget_pin, []) do
    with :ok <- CellularPIN.forget(), do: {:ok, cached()}
  end

  defp execute(name, :unlock, [pin]) do
    with :pin_required <- sim_state(command(name, "AT+CPIN?")),
         :ok <- CellularPIN.block(),
         :ok <- unlock_and_save(name, pin, nil),
         :ok <- resume(name) do
      read_result(name)
    else
      {:error, _} = error -> error
      _ -> {:error, :cellular_sim_changed}
    end
  end

  defp execute(name, operation, params) do
    with :ready <- sim_state(command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         {:ok, cmd, pin} <- security_command(name, operation, params),
         :ok <- CellularPIN.block(),
         :ok <- write(name, cmd),
         {:ok, ^identity} <- verify_ready(name, identity),
         :ok <- remember(operation, params, pin, identity) do
      read_result(name)
    else
      {:error, _} = error -> error
      nil -> {:error, :cellular_identity_unknown}
      _ -> {:error, :cellular_sim_not_ready}
    end
  end

  defp unlock_and_save(name, pin, expected_identity) do
    with :ok <- write(name, ~s(AT+CPIN="#{pin}")),
         {:ok, identity} <- verify_ready(name, expected_identity) do
      CellularPIN.save(pin, identity)
    end
  end

  # A successful acknowledgement AND fresh READY/identity checks are required to
  # re-arm, including after an automatic unlock. A timeout never re-arms it.
  defp verify_ready(name, expected_identity) do
    with :ready <- sim_state(command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         true <- expected_identity == nil or identity == expected_identity do
      {:ok, identity}
    else
      _ -> {:error, :cellular_outcome_unknown}
    end
  end

  defp remember(:set_pin_lock, [false, _], _, _), do: CellularPIN.forget()
  defp remember(_, _, pin, identity), do: CellularPIN.save(pin, identity)

  defp security_command(_, :change_pin, [current, new]),
    do: {:ok, ~s(AT+CPWD="SC","#{current}","#{new}"), new}

  defp security_command(_, :set_pin_lock, [enabled, pin]),
    do: {:ok, ~s(AT+CLCK="SC",#{if enabled, do: 1, else: 0},"#{pin}"), pin}

  defp security_command(name, :save_pin, [pin]) do
    case pin_lock(command(name, ~s(AT+CLCK="SC",2))) do
      :enabled -> security_command(name, :set_pin_lock, [true, pin])
      :disabled -> security_command(name, :set_pin_lock, [false, pin])
      _ -> {:error, :cellular_outcome_unknown}
    end
  end

  defp write(name, cmd) do
    case command(name, cmd, 10_000) do
      {:ok, _} ->
        :ok

      {:error, {:cme, reason}} when reason in ["16", "incorrect password"] ->
        {:error, :cellular_incorrect_pin}

      _ ->
        {:error, :cellular_outcome_unknown}
    end
  end

  # Initial ECM setup may have run while SIM-locked. Reapply only this interface
  # through VintageNet so its own controller redoes radio/APN setup. Null is
  # temporary, never persisted; no second UART owner and no PIN replay.
  defp resume(name) do
    config = VintageNet.get_configuration(name)

    with %{type: VintageNetECM} <- config,
         :ok <- VintageNet.configure(name, %{type: VintageNet.Technology.Null}, persist: false),
         :ok <- VintageNet.configure(name, config, persist: false) do
      :ok
    else
      _ -> {:error, :cellular_resume_failed}
    end
  end

  defp read_result(name) do
    data = read(name)
    if data.sim == :unknown, do: {:error, :cellular_read_failed}, else: {:ok, data}
  end

  defp identity(name), do: sim_identity(command(name, "AT+QCCID"))

  @doc false
  def sim_identity({:ok, lines}) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\A\+QCCID:\s*([0-9]{18,22})[fF]?\s*\z/, line) do
        [_, identity] -> identity
        _ -> nil
      end
    end)
  end

  def sim_identity(_), do: nil

  defp read(name) do
    sim = sim_state(command(name, "AT+CPIN?"))

    data = %{
      empty()
      | sim: sim,
        registration: registration(command(name, "AT+CEREG?")),
        refreshed_at: System.system_time(:millisecond)
    }

    data =
      Map.merge(
        data,
        CellularPIN.metadata(if(sim in [:ready, :pin_required], do: identity(name)))
      )

    if sim == :ready or sim == :pin_required do
      registered = sim == :ready and data.registration in [:registered_home, :registered_roaming]

      lock =
        if sim == :pin_required, do: :enabled, else: pin_lock(command(name, ~s(AT+CLCK="SC",2)))

      %{
        data
        | pin_lock: lock,
          pin_attempts_remaining: attempts(command(name, "AT+QPINC?")),
          operator: if(registered, do: mobile(name, "operator")),
          signal_dbm: if(registered, do: mobile(name, "signal_dbm"))
      }
    else
      data
    end
  end

  defp command(name, cmd, timeout \\ 2_000),
    do: VintageNetECM.command(name, cmd, timeout: timeout)

  defp mobile(name, key), do: VintageNet.get(["interface", name, "mobile", key])

  @doc false
  def sim_state({:ok, lines}) do
    Enum.find_value(lines, :unknown, fn line ->
      case String.trim(line) do
        "+CPIN: READY" -> :ready
        "+CPIN: SIM PIN" -> :pin_required
        "+CPIN: SIM PUK" -> :puk_required
        "+CPIN: SIM PIN2" -> :pin2_required
        "+CPIN: SIM PUK2" -> :puk2_required
        _ -> nil
      end
    end)
  end

  def sim_state({:error, {:cme, reason}}) when reason in ["10", "SIM not inserted"], do: :absent
  def sim_state(_), do: :unknown

  @doc false
  def pin_lock({:ok, lines}) do
    Enum.find_value(lines, :unknown, fn line ->
      case String.trim(line) do
        "+CLCK: 0" -> :disabled
        "+CLCK: 1" -> :enabled
        _ -> nil
      end
    end)
  end

  def pin_lock(_), do: :unknown

  @doc false
  def attempts({:ok, lines}) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\A\+QPINC:\s*"SC",\s*(\d+),\s*\d+\s*\z/, line) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end
    end)
  end

  def attempts(_), do: nil

  @doc false
  def registration({:ok, lines}) do
    if Enum.any?(lines, &Regex.match?(~r/\A\+CEREG:\s*\d+,\s*\d+/, &1)),
      do: VintageNetECM.ATController.parse_registration(lines),
      else: :unknown
  end

  def registration(_), do: :unknown

  defp technology_key(%{vintage_net_ecm: options}) when is_map(options), do: :vintage_net_ecm
  defp technology_key(%{vintage_net_qmi: options}) when is_map(options), do: :vintage_net_qmi

  defp technology_key(%{vintage_net_mobile: options}) when is_map(options),
    do: :vintage_net_mobile

  defp technology_key(_), do: nil
end

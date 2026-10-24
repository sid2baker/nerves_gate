defmodule NervesGate.Cellular.SIM do
  @moduledoc """
  SIM-bound PIN for automatic unlock, kept in the persistent `NervesGate.Settings`
  table. Never put it in domain state or projections.

  Persistence is not encryption: anyone who can read the data partition can read
  the PIN. Consuming the PIN blocks further automatic attempts before returning
  it; only a known-successful PIN operation may save and arm it again. Observing
  READY alone must never re-arm it.
  """

  alias NervesGate.Cellular
  alias NervesGate.Cellular.{Authentication, Modem, Profile}

  @table NervesGate.Settings

  @key ["cellular", "pin"]

  @error {:error,
          %{
            code: "cellular_pin_storage",
            message:
              "The SIM PIN could not be saved. The SIM operation may already have succeeded; read status rather than resending it. Automatic unlock sends no PIN unless its safety latch is persisted first."
          }}

  @doc false

  def save(pin, identity, table \\ @table) do
    if valid_pin?(pin) and valid_identity?(identity),
      do: put(table, %{pin: pin, sim_fingerprint: fingerprint(identity), armed: true}),
      else: @error
  end

  @doc false

  def block(table \\ @table) do
    case PropertyTable.get(table, @key) do
      nil -> :ok
      record -> put(table, %{record | armed: false})
    end
  end

  @doc false

  def consume(identity, table \\ @table) do
    with record when record != nil <- PropertyTable.get(table, @key),
         :ready <- state(record, identity),
         :ok <- put(table, %{record | armed: false}) do
      {:ok, record.pin}
    else
      nil ->
        {:error,
         %{code: "cellular_pin_not_saved", message: "No SIM PIN is saved on this device."}}

      state when is_atom(state) ->
        {:error,
         %{
           code: "cellular_auto_unlock_blocked",
           message:
             "Automatic unlock is blocked or the SIM identity could not be matched. Verify the SIM and explicitly unlock or save its PIN; no automatic retry was sent."
         }}

      error ->
        error
    end
  end

  @doc false

  def forget(table \\ @table) do
    PropertyTable.delete(table, @key)
    flush(table)
  end

  @doc false

  def metadata(identity \\ nil, table \\ @table) do
    case PropertyTable.get(table, @key) do
      nil -> %{pin_saved: false, auto_unlock: :off}
      record -> %{pin_saved: true, auto_unlock: state(record, identity)}
    end
  end

  defp state(%{armed: false}, _), do: :blocked

  defp state(record, identity) do
    cond do
      not valid_identity?(identity) -> :identity_unknown
      record.sim_fingerprint != fingerprint(identity) -> :different_sim
      true -> :ready
    end
  end

  defp put(table, record) do
    PropertyTable.put(table, @key, record)
    flush(table)
  end

  defp flush(table) do
    case PropertyTable.flush_to_disk(table) do
      :ok -> :ok
      _ -> @error
    end
  end

  defp valid_pin?(pin), do: is_binary(pin) and Regex.match?(~r/\A[0-9]{4,8}\z/, pin)

  defp valid_identity?(identity),
    do: is_binary(identity) and Regex.match?(~r/\A[0-9]{18,22}\z/, identity)

  defp fingerprint(identity), do: :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)

  def initialize do
    with %{interface: name, sim_detect_level: level} <- Profile.get(),
         :ok <- Modem.initialize(name, level) do
      read_result(name)
    else
      _ ->
        {:error,
         %{
           code: "cellular_setup_failed",
           message:
             "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
         }}
    end
  catch
    _, _ ->
      {:error,
       %{
         code: "cellular_setup_failed",
         message:
           "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
       }}
  end

  def perform(operation, params) do
    with :ok <- Cellular.parameters(operation, params),
         %{interface: name, config: %{type: VintageNetECM}} <- Profile.get() do
      execute(name, operation, params)
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         %{
           code: "cellular_unsupported",
           message:
             "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
         }}
    end
  catch
    _, _ ->
      {:error,
       %{
         code: "cellular_outcome_unknown",
         message:
           "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
       }}
  end

  def auto_unlock do
    with %{interface: name, config: %{type: VintageNetECM}} <- Profile.get(),
         :pin_required <- sim_state(Modem.command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         {:ok, pin} <- consume(identity),
         :ok <- unlock_and_save(name, pin, identity),
         :ok <- resume(name) do
      read_result(name)
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         %{
           code: "cellular_auto_unlock_blocked",
           message:
             "Automatic unlock is blocked or the SIM identity could not be matched. Verify the SIM and explicitly unlock or save its PIN; no automatic retry was sent."
         }}
    end
  catch
    _, _ ->
      {:error,
       %{
         code: "cellular_outcome_unknown",
         message:
           "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
       }}
  end

  defp execute(name, :refresh, []), do: read_result(name)

  defp execute(_, operation, params)
       when operation in [:save_authentication, :forget_authentication] do
    with %{config: %{vintage_net_ecm: %{modem: Modem}}} <- Profile.get(),
         :ok <- save_authentication(operation, params) do
      {:ok, Cellular.cached()}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         %{
           code: "cellular_unsupported",
           message:
             "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
         }}
    end
  end

  defp execute(_, :forget_pin, []) do
    with :ok <- forget(), do: {:ok, Cellular.cached()}
  end

  defp execute(name, :unlock, [pin]) do
    with :pin_required <- sim_state(Modem.command(name, "AT+CPIN?")),
         :ok <- block(),
         :ok <- unlock_and_save(name, pin, nil),
         :ok <- resume(name) do
      read_result(name)
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         %{
           code: "cellular_sim_changed",
           message:
             "The SIM is no longer asking for its PIN, or its state is unknown. Refresh before acting."
         }}
    end
  end

  defp execute(name, operation, params) do
    with :ready <- sim_state(Modem.command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         {:ok, cmd, pin} <- security_command(name, operation, params),
         :ok <- block(),
         :ok <- write(name, cmd),
         {:ok, ^identity} <- verify_ready(name, identity),
         :ok <- remember(operation, params, pin, identity) do
      read_result(name)
    else
      {:error, _} = error ->
        error

      nil ->
        {:error,
         %{
           code: "cellular_identity_unknown",
           message:
             "The modem could not identify this SIM. Its PIN cannot be safely saved or used automatically. Refresh before acting; do not repeat an accepted PIN command."
         }}

      _ ->
        {:error,
         %{
           code: "cellular_sim_not_ready",
           message: "The SIM must be unlocked and ready before changing PIN security."
         }}
    end
  end

  defp save_authentication(:save_authentication, [apn, username, password]),
    do: Authentication.save(apn, username, password)

  defp save_authentication(:forget_authentication, []), do: Authentication.forget()

  defp unlock_and_save(name, pin, expected_identity) do
    with :ok <- write(name, ~s(AT+CPIN="#{pin}")),
         {:ok, identity} <- verify_ready(name, expected_identity) do
      save(pin, identity)
    end
  end

  # A successful acknowledgement AND fresh READY/identity checks are required to
  # re-arm, including after an automatic unlock. A timeout never re-arms it.
  defp verify_ready(name, expected_identity) do
    with :ready <- sim_state(Modem.command(name, "AT+CPIN?")),
         identity when is_binary(identity) <- identity(name),
         true <- expected_identity == nil or identity == expected_identity do
      {:ok, identity}
    else
      _ ->
        {:error,
         %{
           code: "cellular_outcome_unknown",
           message:
             "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
         }}
    end
  end

  defp remember(:set_pin_lock, [false, _], _, _), do: forget()

  defp remember(_, _, pin, identity), do: save(pin, identity)

  defp security_command(_, :change_pin, [current, new]),
    do: {:ok, ~s(AT+CPWD="SC","#{current}","#{new}"), new}

  defp security_command(_, :set_pin_lock, [enabled, pin]),
    do: {:ok, ~s(AT+CLCK="SC",#{if enabled, do: 1, else: 0},"#{pin}"), pin}

  defp security_command(name, :save_pin, [pin]) do
    case pin_lock(Modem.command(name, ~s"AT+CLCK=\"SC\",2")) do
      :enabled ->
        security_command(name, :set_pin_lock, [true, pin])

      :disabled ->
        security_command(name, :set_pin_lock, [false, pin])

      _ ->
        {:error,
         %{
           code: "cellular_outcome_unknown",
           message:
             "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
         }}
    end
  end

  defp write(name, cmd) do
    case Modem.command(name, cmd, 10_000) do
      {:ok, _} ->
        :ok

      {:error, {:cme, reason}} when reason in ["16", "incorrect password"] ->
        {:error,
         %{
           code: "cellular_incorrect_pin",
           message:
             "The modem rejected the PIN. No retry was sent. Refresh the SIM state and attempts before trying again."
         }}

      _ ->
        {:error,
         %{
           code: "cellular_outcome_unknown",
           message:
             "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
         }}
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
      _ ->
        {:error,
         %{
           code: "cellular_resume_failed",
           message:
             "The PIN was accepted, but cellular configuration could not restart. Read status and reapply network settings; do not resend the PIN."
         }}
    end
  end

  defp read_result(name) do
    data = read(name)

    if data.sim == :unknown,
      do:
        {:error,
         %{
           code: "cellular_read_failed",
           message:
             "The modem did not report a known SIM state. Refresh later; unknown does not mean the SIM is absent."
         }},
      else: {:ok, data}
  end

  defp identity(name), do: sim_identity(Modem.command(name, "AT+QCCID"))

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
    sim = sim_state(Modem.command(name, "AT+CPIN?"))

    data = %{
      Cellular.empty()
      | sim: sim,
        registration: registration(Modem.command(name, "AT+CEREG?")),
        refreshed_at: System.system_time(:millisecond)
    }

    data =
      Map.merge(
        data,
        metadata(if(sim in [:ready, :pin_required], do: identity(name)))
      )
      |> Map.merge(Authentication.metadata())

    if sim == :ready or sim == :pin_required do
      registered = sim == :ready and data.registration in [:registered_home, :registered_roaming]

      lock =
        if sim == :pin_required,
          do: :enabled,
          else: pin_lock(Modem.command(name, ~s"AT+CLCK=\"SC\",2"))

      %{
        data
        | pin_lock: lock,
          pin_attempts_remaining: attempts(Modem.command(name, "AT+QPINC?")),
          operator: if(registered, do: mobile(name, "operator")),
          signal_dbm: if(registered, do: mobile(name, "signal_dbm"))
      }
    else
      data
    end
  end

  defp mobile(name, key), do: VintageNet.get(["interface", name, "mobile", key])

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

  def attempts({:ok, lines}) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\A\+QPINC:\s*"SC",\s*(\d+),\s*\d+\s*\z/, line) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end
    end)
  end

  def attempts(_), do: nil

  def registration({:ok, lines}) do
    if Enum.any?(lines, &Regex.match?(~r/\A\+CEREG:\s*\d+,\s*\d+/, &1)),
      do: VintageNetECM.ATController.parse_registration(lines),
      else: :unknown
  end

  def registration(_), do: :unknown
end

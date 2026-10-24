defmodule NervesGate.Cellular do
  @moduledoc """
  SIM commissioning and private APN-bound PAP credentials.

  Commands return acceptance, not completion. Network owns admission and the
  bounded worker; VintageNetECM is the only UART owner. Read cellular status for
  completion. Never replay a PIN or credential command after an uncertain result.
  PIN operations are one attempt and clear credentials from the requesting UI.
  Saved PAP applies before fresh packet-context activation, not an active session.
  """
  alias NervesGate.Cellular.{Authentication, Modem, SIM}
  alias NervesGate.{Config, Error, Network}

  def refresh, do: submit(:refresh, [])
  def unlock(pin), do: submit(:unlock, [pin])
  def change_pin(current, new), do: submit(:change_pin, [current, new])
  def set_pin_lock(enabled, pin), do: submit(:set_pin_lock, [enabled, pin])
  def save_pin(pin), do: submit(:save_pin, [pin])
  def forget_pin, do: submit(:forget_pin, [])

  def save_authentication(apn, username, password),
    do: submit(:save_authentication, [apn, username, password])

  def forget_authentication, do: submit(:forget_authentication, [])

  defp submit(operation, params) do
    Error.protect(fn -> GenServer.call(Network, {:cellular, operation, params}) end)
  end

  @doc false
  def empty do
    %{
      sim: :unknown,
      pin_saved: nil,
      auto_unlock: :unknown,
      authentication: :unknown,
      authentication_apn: nil,
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
  def cached do
    empty() |> Map.merge(SIM.metadata()) |> Map.merge(Authentication.metadata())
  end

  @doc false
  def reset(data) do
    cached =
      Map.take(data, [
        :pin_saved,
        :auto_unlock,
        :authentication,
        :authentication_apn,
        :operation,
        :error
      ])

    cached =
      if cached[:auto_unlock] in [:ready, :different_sim],
        do: Map.put(cached, :auto_unlock, :identity_unknown),
        else: cached

    Map.merge(empty(), cached)
  end

  @doc false
  def view(nil), do: Map.merge(empty(), %{supported: false, enabled: false, present: nil})

  def view(status) do
    observed = status.observed || %{}
    supported = Map.get(observed, :cellular_supported, false)
    network = NervesGate.Observations.Network.settings(status)
    enabled = supported and Config.cellular?(network)
    present = get_in(observed, [:cellular, :present])
    cached = Map.get(status, :cellular) || empty()
    data = if enabled and present, do: cached, else: reset(cached)
    Map.merge(data, %{supported: supported, enabled: enabled, present: present})
  end

  @doc false
  def available(status, operation \\ :refresh)
  def available(nil, _), do: Network.Policy.available(nil)

  def available(status, operation) do
    cellular = view(status)

    cond do
      not cellular.supported ->
        {:error,
         %{
           code: "cellular_unsupported",
           message:
             "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
         }}

      status.recovering ->
        {:error,
         %{
           code: "recovery_in_progress",
           message: "Wait for saved settings to be restored before trying again."
         }}

      status.trial != nil ->
        {:error, %{code: "trial_in_progress", message: "Another client already started a trial."}}

      status.phase != :idle ->
        {:error,
         %{code: "operation_in_progress", message: "Wait for the current operation to finish."}}

      operation in [:forget_pin, :forget_authentication] ->
        :ok

      not cellular.enabled ->
        {:error,
         %{
           code: "cellular_disabled",
           message: "Enable and save a cellular Internet source before modem operations."
         }}

      cellular.present == true ->
        :ok

      true ->
        {:error,
         %{
           code: "cellular_missing",
           message:
             "The configured cellular interface is not detected. Check modem power and USB enumeration."
         }}
    end
  end

  @doc false
  def sim_available(status, sim) do
    with :ok <- available(status) do
      if view(status).sim == sim,
        do: :ok,
        else:
          {:error,
           %{
             code: "cellular_sim_changed",
             message:
               "The SIM is no longer asking for its PIN, or its state is unknown. Refresh before acting."
           }}
    end
  end

  @doc false
  def parameters(:refresh, []), do: :ok
  def parameters(:forget_pin, []), do: :ok
  def parameters(:forget_authentication, []), do: :ok

  def parameters(:save_authentication, [apn, username, password]) do
    if Authentication.valid?(apn, username, password),
      do: :ok,
      else:
        {:error,
         %{
           code: "invalid_parameters",
           message:
             "PAP needs an explicit APN, a 1–64 character username and a 0–64 character password. Use printable ASCII without quotes or backslashes."
         }}
  end

  def parameters(:save_pin, [pin]), do: valid_pins([pin])
  def parameters(:unlock, [pin]), do: valid_pins([pin])
  def parameters(:change_pin, [current, new]), do: valid_pins([current, new])
  def parameters(:set_pin_lock, [enabled, pin]) when is_boolean(enabled), do: valid_pins([pin])

  def parameters(_, _),
    do:
      {:error,
       %{
         code: "invalid_parameters",
         message: "Use 4–8 digit SIM PINs and a boolean PIN-protection setting."
       }}

  defp valid_pins(pins) do
    if Enum.all?(pins, &(is_binary(&1) and Regex.match?(~r/\A[0-9]{4,8}\z/, &1))),
      do: :ok,
      else: parameters(:invalid, [])
  end

  @doc false
  def perform(operation, params), do: SIM.perform(operation, params)

  # The lifecycle choice belongs here, not in Network's scheduler. Recording the
  # controller before starting initialization prevents resetting an uncertain SIM.
  @doc false
  def next(status, previous_controller) do
    controller = Modem.controller()
    data = status.cellular

    due =
      data.refreshed_at == nil or System.system_time(:millisecond) - data.refreshed_at >= 30_000

    cond do
      available(status) != :ok ->
        nil

      is_pid(controller) and controller != previous_controller ->
        {controller, :initialize, &SIM.initialize/0}

      data.sim == :pin_required and data.auto_unlock == :ready ->
        {previous_controller, :auto_unlock, &SIM.auto_unlock/0}

      due ->
        {previous_controller, :refresh, fn -> perform(:refresh, []) end}

      true ->
        nil
    end
  end

  @doc false
  def complete(result) do
    data =
      case result do
        {:ok, data} ->
          data

        {:error, %{code: code, message: message}} when is_binary(code) and is_binary(message) ->
          %{cached() | error: Error.new(code, message)}

        _ ->
          %{
            cached()
            | error: %{
                code: "cellular_outcome_unknown",
                message:
                  "The cellular result is uncertain. Refresh SIM state before acting. PIN changes cannot be verified by reading; never blindly replay a PIN command."
              }
          }
      end

    %{data | operation: nil, refreshed_at: System.system_time(:millisecond)}
  end

  # Filter before handlers, including RingLogger; dependency crash reports may
  # contain their last AT command. Unknown shapes must not disable this filter.
  @doc false
  def filter_log(event, _) do
    redact(event)
  catch
    _, _ -> :stop
  end

  defp redact({:cellular, operation, _}), do: {:cellular, operation, :redacted}

  defp redact({module, function, args})
       when module in [__MODULE__, SIM, Authentication, Modem] and is_list(args),
       do: {module, function, :redacted}

  defp redact(value) when is_binary(value) do
    cond do
      Regex.match?(~r/AT\+(?:CPIN|CPWD|CLCK)=/, value) -> "[REDACTED SIM COMMAND]"
      Regex.match?(~r/AT\+(?:QICSGP|CGAUTH)=/, value) -> "[REDACTED CELLULAR COMMAND]"
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

  defp redact(value) when is_map(value), do: value |> Map.to_list() |> Map.new(&redact/1)
  defp redact(value), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    String.contains?(key, "pin") or String.contains?(key, "password") or
      key in ["username", "fingerprint", "identity", "iccid", "imsi", "imei"]
  end
end

defmodule Scenarios.Cases.CellularModemSupport do
  @moduledoc "Read-only modem and SMS qualification through the existing UART owner."
  import ExUnit.Assertions
  alias Scenarios.Device

  @sms_tests ["AT+CMGS=?", "AT+CMGR=?", "AT+CMGL=?", "AT+CMGD=?", "AT+CPMS=?"]
  @queries [
             "AT",
             "AT+CGMM",
             "AT+CGMR",
             "AT+CMEE?",
             "AT+CUSD=?",
             "AT+CUSD?",
             "AT+CMGF=?",
             "AT+CMGF?",
             "AT+CPMS?"
           ] ++ @sms_tests

  def spec do
    %{
      name: "Modem SMS qualification (read-only; no messages sent, read or deleted)",
      requires: %{device: [:cellular], fixture: [:physical]},
      opt_in: true
    }
  end

  def run(%{device: device}) do
    status = Device.status(device)
    assert status != nil and status.device.available, "Gateway status is unavailable"

    assert get_in(status, [:actions, "cellular.refresh", :enabled]) == true,
           "Wait for network/SIM operations and recovery to finish before probing the modem"

    assert status.cellular.sim == :ready, "The SIM must already be ready; no PIN is sent"

    profile = Device.rpc(device, NervesGate.Cellular.Profile, :get)

    interface =
      case profile do
        %{
          interface: interface,
          config: %{
            type: VintageNetECM,
            vintage_net_ecm: %{modem: NervesGate.Cellular.Modem}
          }
        }
        when is_binary(interface) ->
          interface

        _ ->
          nil
      end

    assert is_binary(interface), "This check requires the qualified VintageNetECM cellular driver"

    # No sessions, calls, error-mode changes or second UART. Never report raw
    # replies: unrelated unsolicited messages may contain private data.
    {summaries, responses, complete} =
      Enum.reduce_while(@queries, {[], %{}, true}, fn command, {summaries, responses, _} ->
        response = query(device, interface, command)
        summary = command <> ": " <> describe(command, response)
        next = {summaries ++ [summary], Map.put(responses, command, response), true}

        case {command, response} do
          {_, {:ok, _}} -> {:cont, next}
          {"AT", _} -> {:halt, put_elem(next, 2, false)}
          {_, {:error, :error}} -> {:cont, next}
          {_, {:error, {:cme, _}}} -> {:cont, next}
          {_, {:error, {:cms, _}}} -> {:cont, next}
          _ -> {:halt, put_elem(next, 2, false)}
        end
      end)

    summary = Enum.join(summaries, "; ")
    suffix = "No SMS was sent, read or deleted; no settings were changed."
    assert complete, "Modem diagnostic incomplete; stopped without retry. #{summary}. #{suffix}"
    supported = sms_supported?(responses)
    assert supported, "SMS command support is not established. #{summary}. #{suffix}"

    if report = Process.get(:scenario_report),
      do: report.(summary <> ". Command interfaces accepted; SMS delivery remains unverified.")

    :ok
  end

  @doc "Classify only advertised command support, never carrier or balance-query support."
  def classify({:ok, lines}) when is_list(lines) do
    if advertised?(lines, "+CUSD:", 1), do: :supported, else: :inconclusive
  end

  def classify({:error, :error}), do: :rejected
  def classify({:error, {:cme, _}}), do: :rejected
  def classify({:error, :timeout}), do: :timeout
  def classify(_), do: :inconclusive

  @doc "Require advertised PDU format and accepted SMS command tests, not end-to-end delivery."
  def sms_supported?(responses) when is_map(responses) do
    pdu? =
      case Map.get(responses, "AT+CMGF=?") do
        {:ok, lines} -> advertised?(lines, "+CMGF:", 0)
        _ -> false
      end

    pdu? and
      Enum.all?(@sms_tests, &match?({:ok, lines} when is_list(lines), Map.get(responses, &1)))
  end

  def sms_supported?(_), do: false

  defp advertised?(lines, prefix, wanted) when is_list(lines) do
    case field(lines, prefix) do
      nil ->
        false

      value ->
        case Regex.run(~r/\A\s*\(([0-2,\s-]+)\)\s*\z/, value) do
          [_, modes] ->
            choices = %{
              "0" => [0],
              "1" => [1],
              "2" => [2],
              "0-1" => [0, 1],
              "0-2" => [0, 1, 2],
              "1-2" => [1, 2]
            }

            tokens = modes |> String.replace(~r/\s/, "") |> String.split(",")

            Enum.all?(tokens, &Map.has_key?(choices, &1)) and
              Enum.any?(tokens, &(wanted in Map.fetch!(choices, &1)))

          _ ->
            false
        end
    end
  end

  defp advertised?(_, _, _), do: false

  @doc "A bounded diagnostic description with no raw modem text or unrecognized error details."
  def describe("AT", {:ok, _}), do: "OK"

  def describe(command, {:ok, lines}) when command in ["AT+CGMM", "AT+CGMR"] do
    case version(lines) do
      nil -> "OK; model/revision not recognized (details withheld)"
      value -> value
    end
  end

  def describe("AT+CMGF=?", {:ok, lines}) do
    if advertised?(lines, "+CMGF:", 0),
      do: "OK; PDU format advertised",
      else: "OK; PDU format not established"
  end

  def describe("AT+CMGF?", {:ok, lines}) do
    case mode(lines, "+CMGF:") do
      "0" -> "PDU format selected"
      "1" -> "text format selected"
      _ -> "OK; SMS format not recognized"
    end
  end

  def describe("AT+CPMS?", {:ok, lines}), do: storage(lines)
  def describe(command, {:ok, _}) when command in @sms_tests, do: "OK; command test accepted"

  def describe("AT+CMEE?", {:ok, lines}) do
    case mode(lines, "+CMEE:") do
      "0" -> "CMEE=0 (extended errors disabled)"
      "1" -> "CMEE=1 (numeric extended errors)"
      "2" -> "CMEE=2 (verbose extended errors)"
      _ -> "OK; error mode not recognized"
    end
  end

  def describe("AT+CUSD=?", {:ok, _} = response) do
    if classify(response) == :supported,
      do: "OK; request mode 1 advertised",
      else: "OK; no recognized request-mode advertisement"
  end

  def describe("AT+CUSD?", {:ok, lines}) do
    case mode(lines, "+CUSD:") do
      nil -> "OK; USSD mode not recognized"
      mode -> "CUSD=" <> mode
    end
  end

  def describe(_, {:error, :error}), do: "ERROR (no extended cause supplied)"
  def describe(_, {:error, {:cme, detail}}), do: cme(detail)
  def describe(_, {:error, {:cms, _}}), do: "CMS error (details withheld)"
  def describe(_, {:error, :timeout}), do: "timeout"
  def describe(_, {:error, :not_running}), do: "controller unavailable or call outcome unknown"
  def describe(_, {:error, :tty_not_open}), do: "controller UART not open"
  def describe(_, _), do: "inconclusive (details withheld)"

  defp query(device, interface, command) do
    Device.rpc(device, NervesGate.Cellular.Modem, :command, [interface, command, 2_000])
  rescue
    # Transport-loss exits still propagate and fence the job. Other dependency
    # exceptions can contain unsolicited modem data, so never expose them.
    _ -> :inconclusive
  end

  defp version(lines) when is_list(lines) do
    versions =
      Enum.filter(lines, fn line ->
        is_binary(line) and byte_size(line) <= 96 and String.valid?(line) and
          Regex.match?(~r/\A(?:Revision:\s*)?EG[0-9]{3}[A-Z][A-Za-z0-9_.-]*\z/, line)
      end)

    case versions do
      [value] -> value
      _ -> nil
    end
  end

  defp version(_), do: nil

  defp storage(lines) do
    value = field(lines, "+CPMS:")

    pattern =
      ~r/\A\s*"(SM|ME|MT)",\s*([0-9]{1,5}),\s*([0-9]{1,5}),\s*"(SM|ME|MT)",\s*([0-9]{1,5}),\s*([0-9]{1,5}),\s*"(SM|ME|MT)",\s*([0-9]{1,5}),\s*([0-9]{1,5})\s*\z/

    case value && Regex.run(pattern, value, capture: :all_but_first) do
      [_, _, _, _, _, _, _, _, _] = fields ->
        slots = Enum.chunk_every(fields, 3)

        valid? =
          Enum.all?(slots, fn [_, used, total] ->
            String.to_integer(used) <= String.to_integer(total)
          end)

        if valid?,
          do:
            Enum.map_join(Enum.zip(~w(read write receive), slots), ", ", fn {label,
                                                                             [memory, used, total]} ->
              "#{label}=#{memory}:#{used}/#{total}"
            end),
          else: "OK; storage counts not recognized"

      _ ->
        "OK; storage counts not recognized"
    end
  end

  defp mode(lines, prefix) do
    value = field(lines, prefix)
    if value in ~w(0 1 2), do: value
  end

  defp field(lines, prefix) when is_list(lines) do
    replies =
      Enum.filter(lines, fn line ->
        is_binary(line) and byte_size(line) <= 128 and String.valid?(line) and
          String.starts_with?(line, prefix)
      end)

    case replies do
      [line] ->
        value = line |> String.replace_prefix(prefix, "") |> String.trim()
        value

      _ ->
        nil
    end
  end

  defp field(_, _), do: nil

  defp cme(detail) when is_binary(detail) and byte_size(detail) <= 64 do
    if String.valid?(detail) do
      case String.downcase(String.trim(detail)) do
        value when value in ["3", "operation not allowed"] ->
          "CME: operation not allowed"

        value when value in ["4", "operation not supported"] ->
          "CME: operation not supported"

        value when value in ["30", "no network service"] ->
          "CME: no network service"

        value ->
          if Regex.match?(~r/\A[0-9]{1,3}\z/, value),
            do: "CME code " <> value,
            else: "CME error (unrecognized detail withheld)"
      end
    else
      "CME error (unrecognized detail withheld)"
    end
  end

  defp cme(_), do: "CME error (unrecognized detail withheld)"
end

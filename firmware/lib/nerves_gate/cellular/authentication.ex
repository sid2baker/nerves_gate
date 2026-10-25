defmodule NervesGate.Cellular.Authentication do
  @moduledoc """
  Private, APN-bound PAP credentials. Network owns writes; the ECM controller
  reads them before activating a data call. No credentials enter interface
  configuration, domain state or projections. Storage is not encrypted.
  """

  @table NervesGate.Settings
  @key ["cellular", "authentication"]
  @storage_error {:error,
                  %{
                    code: "cellular_authentication_storage",
                    message:
                      "PAP credentials could not be saved reliably. Read cellular status before changing them again."
                  }}
  @setup_error {:error,
                %{
                  code: "cellular_authentication_failed",
                  message:
                    "The modem's data context or authentication could not be configured. No data-call activation was attempted."
                }}

  @doc false
  def valid?(apn, username, password) do
    is_binary(apn) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,99}\z/, apn) and
      credential?(username) and username != "" and credential?(password)
  end

  # Quoted AT parameters: bounded printable ASCII without quotes or backslashes.
  defp credential?(value),
    do: is_binary(value) and Regex.match?(~r/\A[\x20-\x21\x23-\x5B\x5D-\x7E]{0,64}\z/, value)

  @doc false
  def save(apn, username, password, table \\ @table) do
    if valid?(apn, username, password) do
      PropertyTable.put(table, @key, %{apn: apn, username: username, password: password})
      flush(table)
    else
      {:error,
       %{
         code: "invalid_parameters",
         message:
           "PAP needs an explicit APN, a 1–64 character username and a 0–64 character password. Use printable ASCII without quotes or backslashes."
       }}
    end
  end

  @doc false
  def forget(table \\ @table) do
    PropertyTable.delete(table, @key)
    flush(table)
  end

  defp flush(table) do
    case PropertyTable.flush_to_disk(table) do
      :ok -> :ok
      _ -> @storage_error
    end
  end

  @doc false
  def load(table \\ @table) do
    record = PropertyTable.get(table, @key)
    if record == nil or valid_record?(record), do: {:ok, record}, else: @storage_error
  end

  @doc false
  def metadata(table \\ @table) do
    case load(table) do
      {:ok, %{apn: apn}} -> %{authentication: :pap, authentication_apn: apn}
      {:ok, _} -> %{authentication: :none, authentication_apn: nil}
      _ -> %{authentication: :unknown, authentication_apn: nil}
    end
  end

  @doc false
  def command(record, {:ok, lines}, context_id) when context_id in 1..8 do
    with true <- record == nil or valid_record?(record),
         apn when is_binary(apn) <- context_apn(lines, context_id) do
      {username, password, mode} = credentials(record, apn)
      {:ok, ~s(AT+QICSGP=#{context_id},1,"#{apn}","#{username}","#{password}",#{mode})}
    else
      _ -> @setup_error
    end
  end

  def command(_, _, _), do: @setup_error

  defp context_apn(lines, context_id) do
    # The actual context may belong to a trial, not saved desired settings.
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\A\+CGDCONT:\s*#{context_id},"IP","([a-zA-Z0-9.-]{0,100})",/, line) do
        [_, apn] -> apn
        _ -> nil
      end
    end)
  end

  defp credentials(%{apn: saved_apn, username: username, password: password}, apn)
       when saved_apn == apn,
       do: {username, password, 1}

  defp credentials(_, _), do: {"", "", 0}

  defp valid_record?(%{apn: apn, username: username, password: password} = record)
       when map_size(record) == 3,
       do: valid?(apn, username, password)

  defp valid_record?(_), do: false
end

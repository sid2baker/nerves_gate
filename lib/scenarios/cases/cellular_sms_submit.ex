defmodule Scenarios.Cases.CellularSmsSubmit do
  @moduledoc "Send one attended EC100 SMS; consume a private runtime recipient and never retry."
  import ExUnit.Assertions
  alias Scenarios.Device

  @message "EC100 SMS session test"

  def spec do
    %{
      name: "Send one EC100 SMS (carrier charges may apply; no retry)",
      requires: %{device: [:cellular], fixture: [:physical]},
      opt_in: true
    }
  end

  @doc "Private, session-specific input outside the checkout. Write only the recipient, mode 0600."
  def recipient_path do
    id = Workbench.Session.identity().id
    if not is_binary(id), do: raise("Use the running Workbench session")
    Path.join(System.tmp_dir!(), "nerves-gate-sms-#{id}.recipient")
  end

  def run(%{device: device}) do
    with {:ok, interface, pdu, length} <- prepare(device) do
      submit(device, interface, pdu, length)
    end
  end

  defp prepare(device) do
    status = Device.status(device)

    assert status != nil and status.device.available,
           "Gateway status is unavailable; no SMS submitted"

    assert status.system.target == "ec100", "This scenario is qualified only for EC100"
    assert status.cellular.sim == :ready, "SIM must already be ready; no PIN is sent"
    assert status.actions["cellular.refresh"].enabled, "Wait for cellular operations to finish"

    assert Device.rpc(device, :erlang, :function_exported, [
             NervesGate.Cellular.Modem,
             :submit_sms,
             3
           ]),
           "Firmware does not support SMS submission; no SMS submitted"

    interface =
      case Device.rpc(device, NervesGate.Cellular.Profile, :get) do
        %{
          interface: name,
          config: %{type: VintageNetECM, vintage_net_ecm: %{modem: NervesGate.Cellular.Modem}}
        } ->
          name

        _ ->
          flunk("Qualified cellular profile is required; no SMS submitted")
      end

    case consume_recipient(recipient_path()) do
      {:ok, pdu, length} ->
        {:ok, interface, pdu, length}

      _ ->
        flunk(
          "Provide a private 0600 recipient file containing one international number; no SMS submitted"
        )
    end
  rescue
    error in ExUnit.AssertionError -> {:error, :known, Exception.message(error) |> String.trim()}
  end

  defp submit(device, interface, pdu, length) do
    case Device.rpc(
           device,
           NervesGate.Cellular.Modem,
           :submit_sms,
           [interface, pdu, length],
           135_000
         ) do
      :ok ->
        if report = Process.get(:scenario_report) do
          report.("Modem accepted one SMS; delivery is unverified. Do not resend automatically.")
        end

        after_status = Device.status(device)

        assert after_status != nil and after_status.device.available and
                 after_status.cellular.sim == :ready and after_status.cellular.error == nil and
                 after_status.storage.error == nil,
               "SMS was accepted but gateway health changed; inspect it without resending"

        :ok

      {:error, :sms_rejected} ->
        {:error, :known, "Modem rejected the SMS; no retry was attempted"}

      {:error, reason}
      when reason in [
             :invalid_sms_pdu,
             :sms_pdu_mode_required,
             :not_running,
             :not_ready,
             :tty_not_open,
             :desynchronized,
             :expired,
             :busy
           ] ->
        {:error, :known, "SMS precondition failed; no SMS submitted"}

      _ ->
        exit(:sms_outcome_unknown)
    end
  end

  @doc false
  def consume_recipient(path) do
    with {:ok, %{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600 and size in 1..32,
         {:ok, text} <- File.read(path),
         :ok <- File.rm(path),
         true <- String.valid?(text) do
      pdu(String.trim(text))
    else
      _ -> {:error, :recipient_input_required}
    end
  end

  @doc false
  def pdu(recipient) when is_binary(recipient) do
    if Regex.match?(~r/\A\+[1-9][0-9]{6,14}\z/, recipient) do
      digits = binary_part(recipient, 1, byte_size(recipient) - 1)
      padded = if rem(byte_size(digits), 2) == 1, do: digits <> "F", else: digits
      address = for <<a, b <- padded>>, into: "", do: <<b, a>>
      body = :unicode.characters_to_binary(@message, :utf8, {:utf16, :big})

      tpdu =
        <<1, 0, byte_size(digits), 0x91>> <>
          Base.decode16!(address) <>
          <<0, 8, byte_size(body)>> <> body

      {:ok, Base.encode16(<<0>> <> tpdu), byte_size(tpdu)}
    else
      {:error, :invalid_recipient}
    end
  end

  def pdu(_), do: {:error, :invalid_recipient}
end

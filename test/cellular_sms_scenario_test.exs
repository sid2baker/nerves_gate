defmodule Workbench.CellularSmsScenarioTest do
  use ExUnit.Case, async: true
  alias Scenarios.Cases.CellularSmsSubmit, as: SMS

  test "SMS is an explicitly selected physical scenario, never part of all" do
    scenario = Scenarios.describe(SMS)
    assert scenario in Scenarios.physical()
    refute scenario in Scenarios.all()
    assert scenario.opt_in
    assert scenario.requires == %{device: [:cellular], fixture: [:physical]}
    assert %{status: :skipped} = Scenarios.run(scenario, %{device: %{}})
  end

  test "encodes one UCS2 SMS with default SMSC and international semi-octet addressing" do
    assert {:ok, encoded, length} = SMS.pdu("+12025550123")

    assert {:ok,
            <<0, 1, 0, 11, 0x91, 0x21, 0x20, 0x55, 0x05, 0x21, 0xF3, 0, 8, size, body::binary>>} =
             Base.decode16(encoded)

    assert size == byte_size(body)
    assert :unicode.characters_to_binary(body, {:utf16, :big}, :utf8) == "EC100 SMS session test"
    assert length == div(byte_size(encoded), 2) - 1
    assert {:ok, even, _} = SMS.pdu("+441632960000")

    assert {:ok, <<0, 1, 0, 12, 0x91, 0x44, 0x61, 0x23, 0x69, 0, 0, _::binary>>} =
             Base.decode16(even)
  end

  test "rejects recipients that could be short codes, malformed or AT input" do
    for recipient <- [
          nil,
          "111",
          "+111",
          "00441632960000",
          "+0123456789",
          "+12025550123\rAT",
          "+1234567890123456"
        ] do
      assert SMS.pdu(recipient) == {:error, :invalid_recipient}
    end
  end

  test "private input is consumed once, and public permissions or symlinks are rejected" do
    path = Path.join(System.tmp_dir!(), "sms-test-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> "-link")
    end)

    File.write!(path, "+12025550123\n", [:exclusive])
    File.chmod!(path, 0o644)
    assert SMS.consume_recipient(path) == {:error, :recipient_input_required}
    File.chmod!(path, 0o600)
    File.ln_s!(path, path <> "-link")
    assert SMS.consume_recipient(path <> "-link") == {:error, :recipient_input_required}
    assert {:ok, _, _} = SMS.consume_recipient(path)
    refute File.exists?(path)
    assert SMS.consume_recipient(path) == {:error, :recipient_input_required}
  end
end

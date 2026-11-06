defmodule NervesGate.Cellular.ModemTest do
  use ExUnit.Case, async: false
  alias NervesGate.Cellular.Modem

  test "invalid SMS PDUs fail before opening a session or sending commands" do
    for {pdu, length} <- [{nil, 1}, {"", 1}, {"0001", 2}, {"0101", 1}, {"00GG", 1}, {"00\r\n", 1}] do
      assert Modem.submit_sms("wwan999", pdu, length) == {:error, :invalid_sms_pdu}
    end
  end

  test "SIM setup waits for managed channel initialization without sending commands" do
    start_supervised!({Registry, keys: :unique, name: VintageNet.Interface.Registry})

    start_supervised!(
      {VintageNetECM.ATController,
       ifname: "wwan999", channel: __MODULE__.MissingChannel, apn: "internet.example"}
    )

    assert {:error, %{code: "cellular_controller_starting"}} = Modem.initialize("wwan999", 1)
    assert Modem.submit_sms("wwan999", "0001", 1) == {:error, :not_ready}

    stop_supervised!(VintageNetECM.ATController)
    assert {:error, %{code: "cellular_controller_starting"}} = Modem.initialize("wwan999", 1)
    assert Modem.submit_sms("wwan999", "0001", 1) == {:error, :not_running}
  end

  test "uncertain session results do not request a data-call restart" do
    for reason <- [
          :timeout,
          :desynchronized,
          :not_running,
          :tty_not_open,
          :outcome_unknown,
          :expired,
          :invalid_session,
          :busy
        ] do
      assert Modem.parse_data_call_active({:error, reason})
    end

    for reason <- [:error, {:cme, "operation not allowed"}, {:cms, "unknown"}] do
      refute Modem.parse_data_call_active({:error, reason})
    end
  end

  test "manual and automatic settings are active only when the fourth field reports a PDN" do
    assert Modem.parse_data_call_active({:ok, ["+QNETDEVCTL: 1,1,0,1"]})
    assert Modem.parse_data_call_active({:ok, ["+QNETDEVCTL: 3,1,1,1"]})

    for response <- [
          [],
          ["+QNETDEVCTL: 0,0,0,0"],
          ["+QNETDEVCTL: 1,1,1,0"],
          ["+QNETDEVCTL: 3,1,1,0"],
          ["+QNETDEVCTL: 1"],
          ["+QNETDEVSTATUS: 1"],
          ["+QNETDEVCTL: 1,1,1,1,0"],
          ["+QNETDEVCTL: 1,0,1,1"]
        ] do
      refute Modem.parse_data_call_active({:ok, response})
    end
  end

  test "an already-active packet context is reused without reapplying PAP or QIACT" do
    assert Modem.packet_active?([~s(+QIACT: 1,1,1,"10.0.0.2")], 1)
    assert Modem.packet_active?([~s(+QIACT: 2,1,1,"10.0.0.2")], 2)
    assert Modem.packet_active?([~s(+QIACT: 1,1,3,"10.0.0.2")], 1)
  end

  test "another active context, including IMS, is not the Internet context" do
    refute Modem.packet_active?([~s(+QIACT: 8,1,1,"10.0.0.2")], 1)
    refute Modem.packet_active?([~s(+QIACT: 1,1,1,"10.0.0.2")], 2)
  end

  test "missing or inactive packet context must be activated" do
    for response <- [[], ["OK"], [~s(+QIACT: 1,0,1,"0.0.0.0")], ["+QIACT: 1,1"]] do
      refute Modem.packet_active?(response, 1)
    end
  end
end

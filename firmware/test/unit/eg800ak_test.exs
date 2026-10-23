defmodule NervesGate.Network.EG800AKTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.EG800AK

  test "manual and automatic settings are active only when the fourth field reports a PDN" do
    assert EG800AK.parse_data_call_active(["+QNETDEVCTL: 1,1,0,1"])
    assert EG800AK.parse_data_call_active(["+QNETDEVCTL: 3,1,1,1"])

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
      refute EG800AK.parse_data_call_active(response)
    end
  end

  test "an already-active packet context is reused without reapplying PAP or QIACT" do
    assert EG800AK.packet_active?([~s(+QIACT: 1,1,1,"10.0.0.2")], 1)
    assert EG800AK.packet_active?([~s(+QIACT: 2,1,1,"10.0.0.2")], 2)
    assert EG800AK.packet_active?([~s(+QIACT: 1,1,3,"10.0.0.2")], 1)
  end

  test "another active context, including IMS, is not the Internet context" do
    refute EG800AK.packet_active?([~s(+QIACT: 8,1,1,"10.0.0.2")], 1)
    refute EG800AK.packet_active?([~s(+QIACT: 1,1,1,"10.0.0.2")], 2)
  end

  test "missing or inactive packet context must be activated" do
    for response <- [[], ["OK"], [~s(+QIACT: 1,0,1,"0.0.0.0")], ["+QIACT: 1,1"]] do
      refute EG800AK.packet_active?(response, 1)
    end
  end
end

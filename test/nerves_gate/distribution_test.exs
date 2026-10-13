defmodule NervesGate.DistributionTest do
  use ExUnit.Case, async: true
  alias NervesGate.Distribution

  @online %{available: true, simulated: false, state: "online", ipv4: "100.88.166.70"}

  test "node identity comes from the runtime IP, without a tailnet domain or hostname" do
    assert Distribution.node_name(@online) == :"nerves_gate@100.88.166.70"

    assert Distribution.node_name(%{@online | ipv4: "100.64.0.2"}) ==
             :"nerves_gate@100.64.0.2"
  end

  test "waits for a real online IPv4 address" do
    for changes <- [
          %{available: false},
          %{simulated: true},
          %{state: "offline"},
          %{ipv4: nil},
          %{ipv4: ""},
          %{ipv4: "::1"},
          %{ipv4: "invalid"},
          %{ipv4: "100.64.0.2\n-setcookie public"}
        ] do
      assert Distribution.node_name(Map.merge(@online, changes)) == nil
    end

    assert Distribution.node_name(%{}) == nil
  end

  test "even a real-looking observation cannot start distribution on the host" do
    refute Node.alive?()
    assert Distribution.ensure_started(@online) == :ok
    refute Node.alive?()
  end
end

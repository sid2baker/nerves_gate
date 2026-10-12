defmodule NervesGate.IndicatorPolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.Indicators.{Button, Policy}

  test "release boundaries and hold feedback are exact and independent" do
    for {duration, action} <- [
          {49, nil},
          {50, :identify},
          {1_999, :identify},
          {2_000, nil},
          {4_999, nil},
          {5_000, :reboot},
          {24_999, :reboot},
          {25_000, :reboot},
          {29_999, :reboot},
          {30_000, :factory_reset},
          {90_000, :factory_reset}
        ] do
      {released, nil} = Button.event(0, -100, Button.new())
      {pressed, nil} = Button.event(1, 0, released)
      {done, ^action} = Button.event(0, duration, pressed)
      assert done.pressed_at == nil
      assert {_, nil} = Button.event(0, duration, done)
    end

    pressed = %{pressed_at: 0, released_at: -100}

    for {time, feedback} <- [
          {0, :normal},
          {4_999, :normal},
          {5_000, :reboot},
          {24_999, :reboot},
          {25_000, :warning},
          {29_999, :warning},
          {30_000, :reset}
        ] do
      assert Button.feedback(pressed, time) == feedback
    end
  end

  test "startup/lost input cannot turn an already-held button into a gesture" do
    {state, nil} = Button.event(1, 0, Button.new())
    {state, nil} = Button.event(2, 30_000, state)
    assert {_, nil} = Button.event(0, 60_000, state)
    {state, nil} = Button.event(0, 60_000, Button.new())
    {state, nil} = Button.event(1, 60_100, state)
    {state, nil} = Button.event(:invalid, 90_100, state)
    assert {_, nil} = Button.event(0, 90_200, state)
  end

  test "duplicates and repeat never extend a press; bounce cancels rather than combines holds" do
    {state, nil} = Button.event(0, 0, Button.new())
    {state, nil} = Button.event(1, 100, state)
    {state, nil} = Button.event(1, 2_000, state)
    {state, nil} = Button.event(2, 3_000, state)
    assert state.pressed_at == 100
    {state, :reboot} = Button.event(0, 5_100, state)
    {state, nil} = Button.event(1, 5_110, state)
    assert {_, nil} = Button.event(0, 35_110, state)
  end

  test "solid needs both internet and healthy Tailscale; Alarmist owns persistent loss" do
    healthy = %{available: true, state: "online", auth_state: "authenticated", health: []}
    clear = %{severity: :none, connection: false}
    fault = %{severity: :warning, connection: true}
    assert Policy.remote_pattern(healthy, true, clear) == :solid
    assert Policy.remote_pattern(healthy, false, clear) == :slow
    assert Policy.remote_pattern(healthy, false, fault) == :fast

    assert Policy.remote_pattern(%{healthy | health: ["control unavailable"]}, true, clear) ==
             :slow

    assert Policy.remote_pattern(%{healthy | health: ["control unavailable"]}, true, fault) ==
             :fast

    assert Policy.remote_pattern(healthy, true, :unknown) == :slow
    assert Policy.remote_pattern(%{available: false}, false, clear) == :slow
    assert Policy.remote_pattern(%{available: false}, false, fault) == :fast
    assert Policy.remote_pattern(%{operation: "connect"}, true, fault) == :slow
    assert Policy.remote_pattern(%{operation: "disconnect"}, false, fault) == :off

    for auth <- ["stopped", "needs_login"] do
      assert Policy.remote_pattern(%{healthy | auth_state: auth}, false, fault) == :off
    end

    assert Policy.remote_pattern(%{healthy | auth_state: "needs_approval"}, true, clear) == :slow
  end

  test "Alarmist severity, unknown observations and precedence" do
    assert Policy.alarm_pattern(%{severity: :none}) == :off
    assert Policy.alarm_pattern(:unknown) == :slow
    assert Policy.alarm_pattern(%{severity: :warning}) == :slow
    assert Policy.alarm_pattern(%{severity: :error}) == :fast

    normal = Policy.normal(%{}, false, %{severity: :none, connection: false})
    assert normal == %{run: :solid, user1: :slow, user2: :off}
    assert Policy.override(normal, :reboot) == %{normal | run: :slow}
    assert Policy.override(normal, :warning) == %{normal | user2: :fast}
    assert Policy.override(normal, :reset) == %{run: :fast, user1: :fast, user2: :fast}
  end

  test "blink frequency is one/four full cycles per second, including negative monotonic time" do
    assert Enum.map([0, 499, 500, 999, 1_000], &Policy.value(:slow, &1)) == [0, 0, 1, 1, 0]
    assert Enum.map([0, 124, 125, 249, 250], &Policy.value(:fast, &1)) == [0, 0, 1, 1, 0]
    assert Policy.value(:fast, -125) == 1
    assert Policy.value(:slow, -500) == 1
    assert Policy.value(:off, -1) == 0
    assert Policy.value(:solid, -1) == 1
  end
end

defmodule NervesGateTest do
  use ExUnit.Case
  doctest NervesGate

  test "greets the world" do
    assert NervesGate.hello() == :world
  end
end

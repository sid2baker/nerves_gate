defmodule IotrouterExpansionTest do
  use ExUnit.Case, async: false

  test "startup opens no transport; missing managed assignment fails before bus startup" do
    assert IotrouterExpansion.health_check() == :ok
    assert IotrouterExpansion.status().state == :stopped
    assert Process.whereis(IotrouterExpansion.Bus) == nil
    assert {:error, :runtime_unavailable} = IotrouterExpansion.start()
    assert Process.whereis(IotrouterExpansion.Bus) == nil
    assert IotrouterExpansion.stop() == :ok
  end
end

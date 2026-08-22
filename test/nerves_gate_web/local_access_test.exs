defmodule NervesGateWeb.LocalAccessTest do
  use ExUnit.Case, async: false

  alias NervesGateWeb.LocalAccess

  setup do
    previous = Application.get_env(:nerves_gate, :local_dashboard)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:nerves_gate, :local_dashboard),
        else: Application.put_env(:nerves_gate, :local_dashboard, previous)
    end)

    :ok
  end

  test "development dashboards accept the isolated QEMU setup network" do
    Application.put_env(:nerves_gate, :local_dashboard, true)

    assert LocalAccess.dashboard?({192, 168, 77, 2})
    assert LocalAccess.dashboard?({100, 64, 0, 20})
    refute LocalAccess.dashboard?({192, 168, 1, 20})
  end

  test "production dashboards remain restricted to the tailnet" do
    Application.put_env(:nerves_gate, :local_dashboard, false)

    refute LocalAccess.dashboard?({192, 168, 77, 2})
    assert LocalAccess.dashboard?({100, 64, 0, 20})
  end
end

defmodule NervesGate.ErrorHandlingTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Network, Observations, Remote}

  defmodule BrokenAdapter do
    def snapshot(_), do: raise("broken snapshot")
    def apply_config(_, _), do: raise("broken apply")
    def execute(_, _, _), do: exit(:adapter_bug)
    def login_url(_), do: throw(:adapter_bug)
  end

  test "adapters do not turn programming faults into normal unavailable results" do
    adapter = {BrokenAdapter, nil}
    assert_raise RuntimeError, "broken snapshot", fn -> Network.Adapter.snapshot(adapter) end
    assert_raise RuntimeError, "broken snapshot", fn -> Remote.Adapter.snapshot(adapter) end

    assert_raise RuntimeError, "broken apply", fn ->
      Network.Adapter.apply_config(adapter, %{})
    end

    assert catch_exit(Remote.Adapter.execute(adapter, :connect, %{})) == :adapter_bug
    assert catch_throw(Remote.Adapter.login_url(adapter)) == :adapter_bug
  end

  test "public API does not hide caller programming errors" do
    assert_raise FunctionClauseError, fn ->
      NervesGate.network_propose(%{"mode" => "unconfigured"}, :not_keyword_options)
    end
  end

  test "unavailable subscriptions are errors, while invalid patterns still raise" do
    assert {:error, :unavailable} = Observations.subscribe([{MissingPropertyTable, ["test"]}])

    assert {:error, %{code: "unavailable"}} =
             NervesGate.subscribe(network: MissingNetwork, remote: nil)

    assert_raise ArgumentError, fn -> Observations.subscribe([{Observations.table(), [42]}]) end
  end

  test "firmware adapters explicitly report stopped observation sources" do
    refute Process.whereis(VintageNet)
    refute Process.whereis(Tailscale.Properties)
    assert Network.Vintage.snapshot(nil) == nil
    refute Remote.Tailscale.snapshot(nil).available
    assert Remote.Tailscale.login_url(nil) == nil
  end
end

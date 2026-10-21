defmodule NervesGateSim.DependencyLocksTest do
  use ExUnit.Case, async: true

  test "firmware and simulator compile the same shared dependency versions" do
    root = Path.expand("../..", __DIR__)
    firmware = Mix.Dep.Lock.read(Path.join(root, "firmware/mix.lock"))
    simulator = Mix.Dep.Lock.read(Path.join(root, "sim/mix.lock"))

    for {app, lock} <- simulator, Map.has_key?(firmware, app) do
      assert firmware[app] == lock,
             "Align #{app} in firmware/mix.lock and sim/mix.lock: root setup compiles both graphs in one VM"
    end
  end
end

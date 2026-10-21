defmodule Dev.DependencyLocksTest do
  use ExUnit.Case, async: true

  test "all shared workstation and firmware dependencies have identical locks" do
    locks =
      for path <- ["mix.lock", "sim/mix.lock", "firmware/mix.lock"],
          do: {path, Mix.Dep.Lock.read(Path.join(Dev.root(), path))}

    for {left, a} <- locks,
        {right, b} <- locks,
        left < right,
        {app, lock} <- a,
        Map.has_key?(b, app) do
      assert lock == b[app],
             "Align #{app} in #{left} and #{right} deliberately with mix deps.update"
    end
  end
end

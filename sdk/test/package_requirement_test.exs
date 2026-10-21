defmodule NervesGateSDK.PackageRequirementTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.NervesGate.Package

  test "the packaged SDK requirement agrees with the Mix dependency" do
    assert :ok = Package.validate_sdk_requirement!([{:nerves_gate_sdk, "~> 0.1.0"}], "~> 0.1.0")

    assert :ok =
             Package.validate_sdk_requirement!(
               [{:nerves_gate_sdk, "~> 0.1.0", path: "../sdk"}],
               "~> 0.1.0"
             )

    assert_raise Mix.Error, ~r/must match/, fn ->
      Package.validate_sdk_requirement!([{:nerves_gate_sdk, "~> 0.2.0"}], "~> 0.1.0")
    end
  end
end

defmodule NervesGateQEMU.IntegrationCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias NervesGateQEMU.{Fault, Gateway, Harness, Runner}
    end
  end

  setup_all do
    cluster = NervesGateQEMU.Harness.ensure_cluster!()
    %{cluster: cluster}
  end

  setup %{cluster: cluster} do
    on_exit(fn ->
      NervesGateQEMU.Runner.start(:all)
      NervesGateQEMU.Fault.heal_all()
    end)

    %{cluster: NervesGateQEMU.Harness.restore!(cluster)}
  end
end

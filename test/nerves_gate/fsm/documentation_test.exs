defmodule NervesGate.FSM.DocumentationTest do
  use ExUnit.Case, async: true

  @fsms [
    NervesGate.Gateway.Configuration,
    NervesGate.Cluster.Peer
  ]

  @reconcilers [
    NervesGate.Internet,
    NervesGate.Tailnet,
    NervesGate.SSH,
    NervesGate.Cluster,
    NervesGate.SubnetRouter,
    NervesGate.Commissioning
  ]

  test "Finitomata documents protocol modules from their standard state diagrams" do
    Enum.each(@fsms, fn subsystem ->
      assert {:docs_v1, _, _, _, %{"en" => documentation}, _, _} = Code.fetch_docs(subsystem)
      assert documentation =~ "```plant_uml"
      assert documentation =~ String.trim(subsystem.graph())
    end)
  end

  test "ordinary reconcilers are not disguised one-state FSMs" do
    Enum.each(@reconcilers, fn reconciler ->
      assert function_exported?(reconciler, :diagnostics, 0)
      refute function_exported?(reconciler, :graph, 0)
      assert is_map(reconciler.diagnostics())
    end)
  end
end

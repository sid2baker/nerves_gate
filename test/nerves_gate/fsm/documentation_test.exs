defmodule NervesGate.FSM.DocumentationTest do
  use ExUnit.Case, async: true

  @subsystems [
    NervesGate.Internet,
    NervesGate.Tailnet,
    NervesGate.SSH,
    NervesGate.Cluster,
    NervesGate.Cluster.Peer,
    NervesGate.SubnetRouter,
    NervesGate.Commissioning,
    NervesGate.Gateway.Configuration,
    NervesGate.DeviceState.Replica
  ]

  test "generated architecture documentation contains every executable graph" do
    documentation = File.read!("docs/lifecycle-machines.md")

    Enum.each(@subsystems, fn subsystem ->
      assert documentation =~ inspect(subsystem)

      subsystem.graph()
      |> String.trim()
      |> String.split("\n")
      |> Enum.each(&assert documentation =~ String.trim(&1))
    end)
  end

  test "subsystem entry documentation includes the executable Mermaid diagram" do
    Enum.each(@subsystems, fn subsystem ->
      assert {:docs_v1, _, _, _, %{"en" => documentation}, _, _} = Code.fetch_docs(subsystem)
      assert documentation =~ "```mermaid\nstateDiagram-v2"
      assert documentation =~ String.trim(subsystem.graph())
    end)
  end

  test "running singleton subsystems expose the common diagnostic contract" do
    diagnostics = [
      NervesGate.Internet.diagnostics(),
      NervesGate.Tailnet.diagnostics(),
      NervesGate.SSH.diagnostics(),
      NervesGate.Cluster.diagnostics(),
      NervesGate.SubnetRouter.diagnostics(),
      NervesGate.Commissioning.diagnostics(),
      NervesGate.Gateway.Configuration.diagnostics()
    ]

    required = [
      :state,
      :desired,
      :observed,
      :blocked_by,
      :last_event,
      :last_error,
      :attempt,
      :retry_at,
      :history
    ]

    Enum.each(diagnostics, fn diagnostic ->
      assert is_map(diagnostic)
      assert Enum.all?(required, &Map.has_key?(diagnostic, &1))
    end)
  end
end

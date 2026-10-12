defmodule NervesGate.ArchitectureTest do
  use ExUnit.Case, async: true
  alias Reach.Check.Architecture

  @moduletag tmp_dir: true

  test "web code cannot call internal scan or sharing entry points", %{tmp_dir: dir} do
    result =
      check(dir, [
        {"web.ex",
         """
         defmodule NervesGateWeb.BoundaryProbe do
           alias NervesGate.{Network, Remote}

           def bypass(equipment, server) do
             Network.scan(equipment, server)
             Network.sharing(:sharing_enable, %{}, server)
             Remote.sharing(:sharing_enable, %{}, server)
           end
         end
         """}
      ])

    assert result.status == "failed"

    assert Enum.sort(Enum.map(result.violations, &{&1.type, &1.call})) == [
             {:forbidden_call, "NervesGate.Network.scan/2"},
             {:forbidden_call, "NervesGate.Network.sharing/3"},
             {:forbidden_call, "NervesGate.Remote.sharing/3"}
           ]
  end

  test "the public facade and Network-owned coordination remain allowed", %{tmp_dir: dir} do
    result =
      check(dir, [
        {"web.ex",
         """
         defmodule NervesGateWeb.BoundaryProbe do
           def request(opts) do
             NervesGate.equipment_scan(opts)
             NervesGate.equipment_share(opts)
           end
         end
         """},
        {"facade.ex",
         """
         defmodule NervesGate do
           def request(equipment, server) do
             NervesGate.Network.scan(equipment, server)
             NervesGate.Network.sharing(:sharing_enable, %{}, server)
           end
         end
         """},
        {"network.ex",
         """
         defmodule NervesGate.Network do
           def request(server), do: NervesGate.Remote.sharing(:sharing_enable, %{}, server)
         end
         """}
      ])

    assert result.status == "ok"
    assert result.violations == []
  end

  defp check(dir, sources) do
    paths =
      Enum.map(sources, fn {name, source} ->
        path = Path.join(dir, name)
        File.write!(path, source)
        path
      end)

    # Parse fixtures without compiling modules or executing their calls.
    paths
    |> Reach.Project.from_sources(source_only: true, plugins: [])
    |> Architecture.run(Reach.Config.read())
  end
end

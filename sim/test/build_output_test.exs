defmodule NervesGateSim.BuildOutputTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias NervesGate.Simulator
  alias NervesGate.Simulator.BuildOutput

  test "reports complete lines across chunk, UTF-8 and ANSI boundaries" do
    owner = self()

    echoed =
      capture_io(fn ->
        output = BuildOutput.new(&send(owner, {:build_output, &1}))

        ["Compiling 12 fi", "les (.ex)\n", "\e[3", "1mfailed caf", <<195>>, <<169>>, "\e[0m"]
        |> Enum.reduce(output, &BuildOutput.collect(&2, &1))
        |> BuildOutput.done()
      end)

    # The terminal receives every byte unchanged.
    assert echoed == "Compiling 12 files (.ex)\n\e[31mfailed café\e[0m"
    assert_received {:build_output, "Compiling 12 files (.ex)"}
    assert_received {:build_output, "failed café"}
    refute_received {:build_output, _}
  end

  test "runs a command under MuonTrap and returns its exit status" do
    owner = self()
    script = "printf 'first\\nlast without newline'; exit 3"

    capture_io(fn ->
      status =
        BuildOutput.run("sh", ["-c", script], [cd: System.tmp_dir!()], fn line ->
          send(owner, {:build_output, line})
        end)

      send(owner, {:status, status})
    end)

    assert_received {:status, 3}
    assert_received {:build_output, "first"}
    assert_received {:build_output, "last without newline"}
  end

  @tag timeout: 30_000
  test "drains output larger than the wrapper's flow-control buffer" do
    echoed =
      capture_io(fn ->
        assert 0 =
                 BuildOutput.run(
                   "sh",
                   # Let MuonTrap drain its capture pipe before the child exits.
                   ["-c", "head -c 1048576 /dev/zero; sleep 1"],
                   [cd: System.tmp_dir!()],
                   fn _ -> :ok end
                 )
      end)

    assert byte_size(echoed) == 1_048_576
  end

  test "the simulator publishes coalesced build progress and ignores stale output" do
    simulator = start_supervised!({Simulator, %{devices: %{}}})
    GenServer.call(simulator, {:subscribe, self()})
    report = &send(simulator, {:output, nil, &1})

    capture_io(fn ->
      output = BuildOutput.collect(BuildOutput.new(report), "Compiling files\n")
      assert_receive {:simulator, %{output: "Compiling files"}}, 1_000

      output = BuildOutput.collect(output, "Linking firmware\n")
      output = BuildOutput.collect(output, "Assembling firmware\n")
      assert_receive {:simulator, %{output: "Assembling firmware"}}, 1_000
      refute_received {:simulator, _}

      output = BuildOutput.collect(output, "Build failed without a newline")
      BuildOutput.done(output)
      assert_receive {:simulator, %{output: "Build failed without a newline"}}, 1_000
    end)

    send(simulator, {:output, make_ref(), "Stale build output"})
    refute_receive {:simulator, _}, 300
  end
end

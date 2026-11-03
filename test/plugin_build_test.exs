defmodule Workbench.PluginBuildTest do
  use ExUnit.Case, async: false
  alias Workbench.PluginBuild
  @moduletag :tmp_dir

  test "firmware inventory excludes mandatory hardware absent from the board", %{tmp_dir: dir} do
    [{module, beam}] =
      Code.compile_string("""
      defmodule PluginBuildFixture do
        use Application
        def start(_, _), do: raise("must not run while building firmware")
      end
      """)

    :code.delete(module)
    :code.purge(module)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    archive = fn app, env ->
      spec =
        {:application, app,
         [
           vsn: ~c"1.0.0",
           modules: [module],
           applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
           mod: {module, []},
           env: [nerves_gate_sdk_requirement: "~> 0.2.0-dev"] ++ env
         ]}

      files = [
        {String.to_charlist("#{app}-1.0.0/ebin/#{app}.app"),
         IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))},
        {String.to_charlist("#{app}-1.0.0/ebin/#{module}.beam"), beam}
      ]

      {:ok, {_, bytes}} = :zip.create(~c"fixture.ez", files, [:memory])
      path = Path.join(dir, "#{app}.ez")
      File.write!(path, bytes)
      path
    end

    required =
      archive.(:required_fixture,
        nerves_gate_hardware: [:iotrouter_expansion],
        nerves_gate_required_hardware: [:iotrouter_expansion]
      )

    optional = archive.(:optional_fixture, nerves_gate_hardware: [:rs485])

    for {target, env} <- [{"ec100", :dev}, {"ec100", :prod}, {"em300", :dev}, {"x86_64", :dev}] do
      root = Path.join(dir, "#{target}_#{env}")
      kinds = PluginBuild.hardware_kinds(target, env)
      report = fn line -> send(self(), {:report, line}) end
      entries = PluginBuild.add!(required, root, %{}, kinds, report)

      if target == "em300" do
        assert Map.has_key?(entries, "required_fixture")
        assert File.exists?(Path.join(root, "required_fixture/1.0.0/package.ez"))
      else
        assert entries == %{}
        refute File.exists?(root)
        assert_receive {:report, "Skipping required_fixture:" <> _}
      end

      # Modbus supports optional RS485 but its TCP mode works on QEMU too.
      assert %{"optional_fixture" => _} = PluginBuild.add!(optional, root, %{}, kinds, report)
    end
  end
end

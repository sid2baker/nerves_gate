defmodule Workbench.TargetBuildTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "reads the ELF interpreter, not an arbitrary embedded musl string" do
    assert Workbench.TargetBuild.interpreter(elf("/lib/ld-musl-x86_64.so.1")) ==
             "/lib/ld-musl-x86_64.so.1"

    assert Workbench.TargetBuild.interpreter(
             elf("/lib64/ld-linux-x86-64.so.2") <> "/lib/ld-musl-x86_64.so.1"
           ) == "/lib64/ld-linux-x86-64.so.2"

    for invalid <- ["", "not ELF", binary_part(elf("loader"), 0, 80)] do
      assert Workbench.TargetBuild.interpreter(invalid) == nil
    end
  end

  test "target guard rejects a host port even when the other port is correct", %{tmp_dir: dir} do
    for {app, name} <- [{"vintage_net", "if_monitor"}, {"nerves_uevent", "uevent"}] do
      path = Path.join([dir, "firmware/_build/x86_64_dev/lib", app, "priv", name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, elf("/lib/ld-musl-x86_64.so.1"))
    end

    assert :ok = Workbench.TargetBuild.verify!(dir)

    File.write!(
      Path.join(dir, "firmware/_build/x86_64_dev/lib/vintage_net/priv/if_monitor"),
      elf("/lib64/ld-linux-x86-64.so.2")
    )

    assert_raise RuntimeError, ~r/not a musl/, fn -> Workbench.TargetBuild.verify!(dir) end
  end

  defp elf(loader) do
    interp = loader <> <<0>>
    size = byte_size(interp)

    header =
      <<0x7F, "ELF", 2, 1, 0::80, 2::little-16, 62::little-16, 1::little-32, 0::64, 64::little-64,
        0::64, 0::32, 64::little-16, 56::little-16, 1::little-16, 0::48>>

    program =
      <<3::little-32, 0::32, 120::little-64, 0::128, size::little-64, size::little-64,
        1::little-64>>

    header <> program <> interp
  end
end

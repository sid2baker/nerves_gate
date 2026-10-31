defmodule Workbench.BuildsTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "firmware options come from actual compatible local archives, not directory names", %{
    tmp_dir: root
  } do
    for {profile, target, product, version} <- [
          {"ec100_dev", "ec100", "nerves_gate", "0.2.0-dev"},
          {"ec100_prod", "ec100", "nerves_gate", "0.1.0"},
          {"ec100_wrong", "x86_64", "nerves_gate", "0.2.0-dev"},
          {"ec100_other", "ec100", "other", "0.2.0-dev"},
          {"em300_dev", "em300", "nerves_gate", "0.3.0-dev"},
          # A board's archive in the other board's build directory is not offered.
          {"em300_prod", "ec100", "nerves_gate", "0.4.0"},
          {"ec100_mixed", "em300", "nerves_gate", "0.5.0"}
        ] do
      dir = Path.join(root, "firmware/_build/#{profile}/nerves/images")
      File.mkdir_p!(dir)
      config = Path.join(dir, "fwup.conf")

      File.write!(config, """
      meta-product = "#{product}"
      meta-platform = "#{target}"
      meta-architecture = "arm"
      meta-version = "#{version}"
      task complete {}
      """)

      assert {_, 0} =
               System.cmd("fwup", ["-c", "-f", config, "-o", Path.join(dir, "nerves_gate.fw")],
                 stderr_to_stdout: true
               )
    end

    File.write!(
      Path.join(root, "firmware/_build/ec100_dev/nerves/images/broken.fw"),
      "not firmware"
    )

    images = Workbench.Builds.images(root)

    assert Enum.sort(Enum.map(images, &{&1.target, &1.version})) == [
             {"ec100", "0.1.0"},
             {"ec100", "0.2.0-dev"},
             {"em300", "0.3.0-dev"}
           ]

    assert Enum.all?(images, &File.regular?(&1.path))
    assert Workbench.Builds.images(Path.join(root, "empty")) == []
  end
end

defmodule Dev.AssetsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_all_env(:volt)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:volt), do: Application.delete_env(:volt, key)
      Application.put_all_env(volt: previous)
    end)

    outdir = Path.join(dir, "assets")
    Application.put_env(:volt, :outdir, outdir)
    {:ok, outdir: outdir}
  end

  test "host asset builds produce complete static files without selecting a device target", %{
    outdir: outdir
  } do
    owner = self()
    target = Mix.target()
    assert :ok = Dev.Builds.assets!(&send(owner, {:progress, &1}))
    assert_received {:progress, "Building frontend assets"}
    assert Mix.target() == target

    js = File.read!(Path.join(outdir, "js/app.js"))
    css = File.read!(Path.join(outdir, "css/app.css"))
    manifest = outdir |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

    assert js =~ "ScrollToBottom"
    assert js =~ "phx:theme"
    refute js =~ "/@volt/"
    assert css =~ ".ui-header"
    refute css =~ ~s(@import "tailwindcss")
    assert get_in(manifest, ["app.js", "file"]) == "js/app.js"
    assert get_in(manifest, ["app.css", "file"]) == "css/app.css"
  end

  test "asset failures abort the firmware pipeline before target compilation", %{tmp_dir: dir} do
    Application.put_env(:volt, :entry, Path.join(dir, "missing.js"))

    firmware = Dev.MixProject.project()[:aliases][:firmware]

    ExUnit.CaptureIO.capture_io(fn ->
      assert_raise RuntimeError, ~r/Asset build failed/, fn ->
        firmware.(["ec100", "--env", "prod"])
      end
    end)
  end

  test "workbench and standalone host builds read the same asset configuration" do
    root =
      Config.Reader.read!(Path.join(Dev.root(), "config/config.exs"),
        env: :dev,
        target: :host
      )

    firmware =
      Config.Reader.read!(Path.join(Dev.root(), "firmware/config/host.exs"),
        env: :dev,
        target: :host
      )

    assert root[:volt] == firmware[:volt]
    assert Path.type(root[:volt][:entry]) == :absolute
    assert Path.type(root[:volt][:outdir]) == :absolute
  end
end

defmodule Workbench.PhysicalAppInstallTest do
  use ExUnit.Case, async: true
  alias Workbench.PhysicalAppInstall, as: Install

  defp metadata,
    do: %{app: "tailnet_subrouter", version: "1.0.0", sdk_requirement: "~> 0.1.0", platform: []}

  defp device do
    %{
      "product" => "nerves_gate",
      "target" => "ec100",
      "firmware" => "test",
      "serial" => "test-board",
      "boot_id" => "11111111-1111-1111-1111-111111111111",
      "sdk_version" => "0.1.0",
      "install_api" => true,
      "storage_ready" => true,
      "card_id" => "card-hash",
      "installed" => false,
      "platform_compatible" => true
    }
  end

  test "physical admission requires identity, new-app API, storage, SDK and no existing install" do
    assert Install.compatible!(metadata(), device()) == :ok

    for {key, value} <- [
          {"product", "other"},
          {"target", "x86_64"},
          {"serial", ""},
          {"boot_id", "bad"},
          {"install_api", false},
          {"storage_ready", false},
          {"card_id", nil},
          {"installed", true},
          {"sdk_version", "1.0.0"},
          {"platform_compatible", false}
        ] do
      assert_raise ArgumentError, fn ->
        Install.compatible!(metadata(), Map.put(device(), key, value))
      end
    end
  end

  test "package metadata is small and JSON serializable, without application code or private state" do
    package = %{
      app: :demo,
      version: "1.2.3",
      main: %{
        env: [nerves_gate_sdk_requirement: "~> 0.1.0", nerves_gate_platform: [jason: "1.4.5"]]
      },
      files: %{private: "not projected"}
    }

    assert Install.metadata(package) == %{
             app: "demo",
             version: "1.2.3",
             sdk_requirement: "~> 0.1.0",
             platform: [["jason", "1.4.5"]]
           }

    assert Jason.encode!(Install.metadata(package))
  end

  @tag :tmp_dir
  test "review kind, token, exact address, expiry and private snapshot cleanup", %{tmp_dir: dir} do
    plan = %{
      public: %{kind: :app_install, token: "token", address: "gateway.example", project: "/app"},
      expires: System.monotonic_time(:millisecond) + 60_000,
      dir: Path.join(dir, "review")
    }

    File.mkdir!(plan.dir)
    assert Install.confirmation!(plan, "token", "gateway.example") == :ok

    for {token, address} <- [
          {nil, "gateway.example"},
          {"other", "gateway.example"},
          {"token", "other"}
        ] do
      assert_raise ArgumentError, fn -> Install.confirmation!(plan, token, address) end
    end

    assert_raise ArgumentError, ~r/expired/, fn ->
      Install.confirmation!(
        %{plan | expires: System.monotonic_time(:millisecond) - 1},
        "token",
        "gateway.example"
      )
    end

    assert Install.cleanup(plan)
    refute File.exists?(plan.dir)
  end

  test "review is read-only; confirmed command installs once and never starts or upgrades" do
    review = Install.review_command(metadata())
    assert {:ok, _} = Code.string_to_quoted(review)
    refute review =~ "File.write"
    refute review =~ "Apps.install_new("
    plan = %{public: %{app: "demo", version: "1.0.0", sha256: "hash"}, device: device()}
    command = Install.install_command(plan, "/tmp/owned", "/tmp/owned/application.ez")
    assert {:ok, _} = Code.string_to_quoted(command)
    assert length(String.split(command, "NervesGate.Apps.install_new(")) == 2
    refute command =~ "Apps.start"
    refute command =~ "Apps.upgrade"
    refute command =~ "Network."
    assert command =~ "running? == false"
    assert command =~ "enabled == false"
    assert command =~ "File.rm_rf"
  end

  @tag :tmp_dir
  test "app reviews cannot authorize firmware, factory, reboot or another project and expire cleanly",
       %{tmp_dir: dir} do
    {:ok, idle} = Workbench.Operations.init(nil)

    plan = %{
      public: %{
        kind: :app_install,
        token: "app-review",
        address: "gateway.example",
        project: "/app"
      },
      dir: Path.join(dir, "snapshot"),
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    File.mkdir!(plan.dir)
    ref = make_ref()
    running = %{idle | task: %{ref: ref}, view: Map.put(idle.view, :context, %{subject: "/app"})}
    assert {:noreply, ready} = Workbench.Operations.handle_info({ref, {:review, plan}}, running)
    assert ready.view.review == plan.public
    refute inspect(ready.view) =~ plan.dir

    for request <- [
          {:confirm_firmware, "app-review", "gateway.example"},
          {:confirm_factory, "app-review", "erase", "true"},
          {:confirm_reboot, "app-review", "gateway.example"},
          {:confirm_app_install, "app-review", "gateway.example", "/other"},
          {:confirm_app_install, "wrong", "gateway.example", "/app"}
        ] do
      assert {:reply, {:error, _}, ^ready} = Workbench.Operations.handle_call(request, nil, ready)
    end

    assert {:noreply, expired} =
             Workbench.Operations.handle_info({:expire_review, "app-review"}, ready)

    assert expired.review == nil
    refute File.exists?(plan.dir)
  end
end

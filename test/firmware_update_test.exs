defmodule Workbench.FirmwareUpdateTest do
  use ExUnit.Case, async: true
  alias Workbench.FirmwareUpdate

  test "image and authenticated device must have matching product and platform" do
    image =
      FirmwareUpdate.metadata(
        "meta-product=nerves_gate\nmeta-platform=ec100\nmeta-architecture=arm\nmeta-version=\"0.2.0-dev\"\nmeta-vcs-identifier=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nignored=private\n"
      )

    device = %{
      "target" => "ec100",
      "platform" => "ec100",
      "architecture" => "arm",
      "product" => "nerves_gate",
      "version" => "0.1.0"
    }

    assert FirmwareUpdate.compatible!(image, device) == :ok
    refute Map.has_key?(image, "ignored")

    assert_raise ArgumentError, fn ->
      FirmwareUpdate.compatible!(Map.delete(image, "meta-vcs-identifier"), device)
    end

    for incompatible <- [
          Map.put(device, "target", "x86_64"),
          Map.put(device, "platform", "x86_64"),
          Map.put(device, "product", "other"),
          Map.put(device, "architecture", "x86_64"),
          %{}
        ] do
      assert_raise ArgumentError, fn -> FirmwareUpdate.compatible!(image, incompatible) end
    end
  end

  test "confirmation must match this unexpired review and exact hostname" do
    plan = %{
      public: %{token: "one-review", address: "ec100.example.ts.net"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    assert :ok = FirmwareUpdate.confirmation!(plan, "one-review", "ec100.example.ts.net")

    for {id, host} <- [
          {nil, "ec100.example.ts.net"},
          {"another-review", "ec100.example.ts.net"},
          {"one-review", "other.example.ts.net"}
        ] do
      assert_raise ArgumentError, fn -> FirmwareUpdate.confirmation!(plan, id, host) end
    end

    expired = %{plan | expires: System.monotonic_time(:millisecond) - 1}

    assert_raise ArgumentError, ~r/expired/, fn ->
      FirmwareUpdate.confirmation!(expired, "one-review", "ec100.example.ts.net")
    end
  end

  test "SSH never accepts unknown host keys or prompts for passwords" do
    options = Workbench.DeviceSSH.options("ec100.example.ts.net")
    assert options[:silently_accept_hosts] == false
    assert options[:save_accepted_host] == false
    assert options[:user_interaction] == false
    assert options[:auth_methods] == ~c"publickey"
    assert options[:user] == ~c"nerves_gate"
    assert {Workbench.SSHHostKeys, callback} = options[:key_cb]
    assert callback[:host] == ~c"ec100.example.ts.net"
    assert callback[:agent] == not is_nil(System.get_env("SSH_AUTH_SOCK"))
    refute Keyword.has_key?(options, :preferred_algorithms)

    for invalid <- [0, -1, 65536, "22;command", "bad"] do
      assert_raise ArgumentError, fn -> FirmwareUpdate.port!(invalid) end
    end

    assert FirmwareUpdate.port!("22") == 22
  end

  test "device reads invoke only current compiled maintenance APIs" do
    assert Workbench.DeviceSSH.identity_command() ==
             "Base.encode64(Jason.encode!(NervesGate.System.maintenance_info()))"

    assert Workbench.DeviceSSH.hardware_command() ==
             "Base.encode64(Jason.encode!(NervesGate.System.hardware_info()))"
  end

  test "connection failures explain common causes without exposing arbitrary server errors" do
    assert Workbench.DeviceSSH.connection_error(:timeout) =~ "timed out"
    assert Workbench.DeviceSSH.connection_error(:econnrefused) =~ "refused"
    assert Workbench.DeviceSSH.connection_error(:nxdomain) =~ "could not be resolved"
    assert Workbench.DeviceSSH.connection_error(~c"Service not available") =~ "authentication"
    refute Workbench.DeviceSSH.connection_error({:server, "private error"}) =~ "private error"
  end

  @tag :tmp_dir
  test "review projection excludes private snapshot state and stale reviews are cleaned", %{
    tmp_dir: dir
  } do
    snapshot_dir = Path.join(dir, "owned-review")
    File.mkdir!(snapshot_dir)
    snapshot = Path.join(snapshot_dir, "image.fw")
    File.write!(snapshot, "owned snapshot")
    public = %{token: "review", address: "ec100.example.ts.net"}

    plan = %{
      owner: Workbench.FirmwareUpdate,
      public: public,
      dir: snapshot_dir,
      snapshot: snapshot,
      device: %{private: "not projected"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    {:ok, idle} = Workbench.Operations.init(nil)
    ref = make_ref()

    assert {:noreply, ready} =
             Workbench.Operations.handle_info({ref, {:review, plan}}, %{idle | task: %{ref: ref}})

    assert ready.view.review == public
    refute inspect(ready.view) =~ "not projected"
    refute inspect(ready.view) =~ snapshot

    assert {:reply, {:error, _}, ^ready} =
             Workbench.Operations.handle_call(
               {:confirm_firmware, "stale", public.address},
               {self(), make_ref()},
               ready
             )

    assert File.exists?(snapshot)

    assert {:noreply, expired} =
             Workbench.Operations.handle_info({:expire_review, "review"}, ready)

    assert expired.review == nil
    refute File.exists?(snapshot_dir)
  end

  test "an update cannot be confirmed without a prepared review" do
    {:ok, state} = Workbench.Operations.init(nil)

    assert {:reply, {:error, _}, ^state} =
             Workbench.Operations.handle_call(
               {:confirm_firmware, "guessed", "ec100.example.ts.net"},
               {self(), make_ref()},
               state
             )
  end
end

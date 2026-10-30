defmodule Workbench.FirmwareUpdateTest do
  use ExUnit.Case, async: false
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

  @tag :tmp_dir
  test "SSH accepts only the reported host keys and never prompts for passwords", %{
    tmp_dir: dir
  } do
    [reported, other] =
      for name <- ["reported", "other"] do
        path = Path.join(dir, name)
        {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
        [{key, _}] = :ssh_file.decode(File.read!(path <> ".pub"), :openssh_key)
        {key, to_string(:ssh.hostkey_fingerprint(:sha256, key))}
      end

    assert_raise FunctionClauseError, fn -> apply(Workbench.SSH, :verified, [[]]) end
    options = Workbench.SSH.verified([elem(reported, 1)])
    assert options[:silently_accept_hosts] == false
    assert options[:auth_methods] == ~c"publickey"
    assert options[:user] == ~c"nerves_gate"
    assert {Workbench.SSHHostKeys, callback} = options[:key_cb]
    assert callback[:agent] == not is_nil(System.get_env("SSH_AUTH_SOCK"))

    accepts? = fn {key, _} ->
      Workbench.SSHHostKeys.is_host_key(key, ~c"peer", 22, :"ssh-ed25519",
        key_cb_private: callback
      )
    end

    assert accepts?.(reported)
    refute accepts?.(other)
    assert {:error, _} = Workbench.SSHHostKeys.add_host_key(~c"h", 22, elem(other, 0), [])
  end

  test "a new healthy boot of the same serial with the reviewed build verifies the update" do
    before = %{"serial" => "s", "boot_id" => "1", "version" => "0.1", "source_revision" => "old"}
    plan = %{before: before, public: %{version: "0.2", source_revision: "new"}}

    healthy = %{
      "serial" => "s",
      "boot_id" => "2",
      "version" => "0.2",
      "source_revision" => "new",
      "available" => true,
      "firmware_validated" => true,
      "pending" => false,
      "recovering" => false
    }

    assert FirmwareUpdate.verified?(plan, healthy)
    refute FirmwareUpdate.verified?(plan, %{healthy | "boot_id" => "1"})
    refute FirmwareUpdate.verified?(plan, %{healthy | "serial" => "other"})
    refute FirmwareUpdate.verified?(plan, %{healthy | "version" => "0.1"})
    refute FirmwareUpdate.verified?(plan, %{healthy | "firmware_validated" => false})
    assert FirmwareUpdate.same_boot?(before, Map.put(before, "available", false))
    refute FirmwareUpdate.same_boot?(before, %{before | "boot_id" => "2"})
  end

  test "changed plugin artifacts under an existing version are conflicts" do
    saved = %{"modbus" => %{artifacts: %{"0.2.1" => %{sha256: "a"}}}}
    same = %{"modbus" => %{artifacts: %{"0.2.1" => %{sha256: "a"}, "0.2.2" => %{sha256: "b"}}}}
    changed = %{"modbus" => %{artifacts: %{"0.2.1" => %{sha256: "c"}}}}
    assert FirmwareUpdate.conflicts(saved, same) == []
    assert FirmwareUpdate.conflicts(saved, changed) == [{"modbus", "0.2.1"}]
    assert FirmwareUpdate.conflicts(%{}, changed) == []
  end

  @tag :tmp_dir
  test "review projection excludes private plan state; stale confirmations and expiry clean up",
       %{
         tmp_dir: dir
       } do
    snapshot_dir = Path.join(dir, "owned-review")
    File.mkdir!(snapshot_dir)
    snapshot = Path.join(snapshot_dir, "image.fw")
    File.write!(snapshot, "owned snapshot")
    public = %{kind: :firmware, token: "review", address: "ec100.example.ts.net"}

    plan = %{
      owner: Workbench.FirmwareUpdate,
      public: public,
      dir: snapshot_dir,
      snapshot: snapshot,
      before: %{"private" => "not projected"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    {:ok, idle} = Workbench.Jobs.init(nil)
    ref = make_ref()

    assert {:noreply, ready} =
             Workbench.Jobs.handle_info({ref, {:review, plan}}, %{idle | task: %{ref: ref}})

    assert ready.view.review == public
    refute inspect(ready.view) =~ "not projected"
    refute inspect(ready.view) =~ snapshot

    assert {:reply, {:error, _}, ^ready} =
             Workbench.Jobs.handle_call(
               {:confirm, :firmware, "stale", [public.address]},
               nil,
               ready
             )

    assert {:reply, {:error, _}, ^ready} =
             Workbench.Jobs.handle_call({:confirm, :factory, "review", ["x", "true"]}, nil, ready)

    assert File.exists?(snapshot)
    assert {:noreply, expired} = Workbench.Jobs.handle_info({:expire, "review"}, ready)
    assert expired.review == nil
    refute File.exists?(snapshot_dir)
  end

  test "an update cannot be confirmed without a prepared review" do
    {:ok, state} = Workbench.Jobs.init(nil)

    assert {:reply, {:error, _}, ^state} =
             Workbench.Jobs.handle_call(
               {:confirm, :firmware, "guessed", ["ec100.example.ts.net"]},
               nil,
               state
             )
  end
end

# Run only via scripts/test_equipment.sh; these are real Linux adapters.
host_ns = System.fetch_env!("NERVES_GATE_HOST_NETNS")
if File.read_link!("/proc/self/ns/net") == host_ns, do: raise("Refusing host network namespace")

ExUnit.start()

defmodule NervesGate.EquipmentIntegrationTest do
  use ExUnit.Case, async: false
  alias NervesGate.Equipment.{Linux, Subnet}

  test "ARP probes stay on the selected equipment interface and receive actual replies" do
    {:ok, scope} =
      Subnet.build("eth1", %{
        "ip_method" => "static",
        "static_ip" => "192.168.50.2",
        "subnet_mask" => "255.255.255.0"
      })

    assert {:ok, devices} = Linux.scan(scope, nil)
    assert [%{ip: "192.168.50.10", source: "ARP reply", mac: mac}] = devices
    assert byte_size(mac) == 17
    System.cmd("ping", ["-c", "1", "-W", "1", "192.168.50.10"])
    assert {:ok, neighbors} = Linux.neighbors(scope, nil)
    assert Enum.any?(neighbors, &(&1.ip == "192.168.50.10" and is_integer(&1.last_seen)))
    assert {:ok, []} = Linux.neighbors(%{scope | interface: "lo"}, nil)
  end

  if System.get_env("NERVES_GATE_TEST_CAN") == "1" do
    test "SocketCAN capture reads vcan without sending or reconfiguring the interface" do
      assert %{present: true, up: true} = NervesGate.Linux.CAN.snapshot("can0")
      task = Task.async(fn -> NervesGate.Linux.CAN.capture("can0") end)
      {:ok, index} = :net.if_name2index(~c"can0")
      {:ok, socket} = :socket.open(29, :raw, 1)
      :ok = :socket.bind(socket, %{family: 29, addr: <<0::16, index::native-32, 0::64>>})
      # Repeated short sends avoid scheduling assumptions about the capture task.
      for _ <- 1..10 do
        :ok = :socket.send(socket, <<0x123::native-32, 2, 0::24, 1, 2, 0::48>>)
        Process.sleep(20)
      end

      :socket.close(socket)
      assert {:ok, frames} = Task.await(task, 6000)
      assert Enum.any?(frames, &(&1.id == "123" and &1.data == "0102"))
      assert Enum.count_until(frames, 201) <= 200
      assert %{present: true, up: true} = NervesGate.Linux.CAN.snapshot("can0")
    end
  else
    IO.puts("SKIP: vcan unavailable in this kernel; physical CAN remains unverified")
  end
end

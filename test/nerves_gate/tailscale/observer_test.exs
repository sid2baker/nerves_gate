defmodule NervesGate.Tailscale.ObserverTest do
  use ExUnit.Case

  alias NervesGate.Tailscale.Observer
  alias NervesGate.TestTailscaleClient

  setup do
    {:ok, _pid} = TestTailscaleClient.reset({:error, :offline})

    on_exit(fn -> stop_if_running(TestTailscaleClient) end)

    :ok
  end

  test "normalizes self state and discovers only online NervesGate peers" do
    normalized = Observer.normalize(online_status())

    assert normalized.online
    assert normalized.ipv4 == "100.64.0.10"
    assert normalized.candidates == [:"nervesgate@100.64.0.11"]
    assert Enum.count(normalized.peers) == 3
    assert Enum.count(normalized.nodes) == 3
  end

  test "loss and recovery of Tailscale are broadcast without crashing observers" do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")
    TestTailscaleClient.put({:ok, online_status()})
    {:ok, observer} = start_observer()

    assert_receive {:tailscale_changed, %{online: true}}, 500
    TestTailscaleClient.put({:error, :daemon_crashed})
    Observer.poll_now(observer)
    assert_receive {:tailscale_changed, %{online: false, error: :status_unavailable}}, 500

    TestTailscaleClient.put({:ok, online_status()})
    Observer.poll_now(observer)
    assert_receive {:tailscale_changed, %{online: true}}, 500
  end

  test "peer disappearance removes the cluster candidate for automatic healing" do
    TestTailscaleClient.put({:ok, online_status()})
    {:ok, observer} = start_observer()
    assert_eventually(fn -> Observer.candidates(observer) == [:"nervesgate@100.64.0.11"] end)

    raw = put_in(online_status(), ["Peer"], %{})
    TestTailscaleClient.put({:ok, raw})
    Observer.poll_now(observer)
    assert_eventually(fn -> Observer.candidates(observer) == [] end)
  end

  defp stop_if_running(name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_observer do
    name = String.to_atom("tailscale_observer_#{System.unique_integer([:positive])}")
    Observer.start_link(name: name, client: TestTailscaleClient, poll_interval: 60_000)
  end

  defp assert_eventually(predicate, attempts \\ 20) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end

  defp online_status do
    %{
      "BackendState" => "Running",
      "Self" => %{
        "Online" => true,
        "HostName" => "nervesgate-m01",
        "TailscaleIPs" => ["100.64.0.10", "fd7a:115c:a1e0::10"]
      },
      "Peer" => %{
        "peer-1" => %{
          "Online" => true,
          "HostName" => "nervesgate-m02",
          "DNSName" => "nervesgate-m02.example.ts.net.",
          "TailscaleIPs" => ["100.64.0.11"]
        },
        "peer-2" => %{
          "Online" => false,
          "HostName" => "nervesgate-m03",
          "TailscaleIPs" => ["100.64.0.12"]
        },
        "laptop" => %{
          "Online" => true,
          "HostName" => "technician-laptop",
          "UserID" => 42,
          "TailscaleIPs" => ["100.64.0.20"]
        }
      },
      "User" => %{
        "42" => %{"DisplayName" => "Ada Operator", "LoginName" => "ada@example.com"}
      }
    }
  end
end

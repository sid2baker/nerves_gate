defmodule NervesGate.BackendSupervisionTest do
  use ExUnit.Case, async: false

  alias NervesGate.DeviceState.Server

  test "DeviceState failure restarts every publisher and rehydrates the public state" do
    old = %{
      server: Process.whereis(Server),
      commissioning: Process.whereis(NervesGate.Commissioning),
      internet: Process.whereis(NervesGate.Internet),
      tailnet: Process.whereis(NervesGate.Tailnet),
      ssh: Process.whereis(NervesGate.SSH),
      subnet_router: Process.whereis(NervesGate.SubnetRouter),
      cluster: Process.whereis(NervesGate.Cluster),
      configuration: Process.whereis(NervesGate.Gateway.Configuration),
      dependencies: Process.whereis(NervesGate.Dependencies),
      alarms: Process.whereis(NervesGate.Alarms.Runtime)
    }

    assert Enum.all?(old, fn {_name, pid} -> is_pid(pid) end)
    Process.exit(old.server, :kill)

    assert_eventually(fn ->
      Enum.all?(old, fn {name, previous} ->
        current = current_pid(name)
        is_pid(current) and current != previous and Process.alive?(current)
      end)
    end)

    assert_eventually(fn -> Server.snapshot().hydrated end, 300)
    assert Server.snapshot().revision > 0
  end

  defp current_pid(:server), do: Process.whereis(Server)
  defp current_pid(:commissioning), do: Process.whereis(NervesGate.Commissioning)
  defp current_pid(:internet), do: Process.whereis(NervesGate.Internet)
  defp current_pid(:tailnet), do: Process.whereis(NervesGate.Tailnet)
  defp current_pid(:ssh), do: Process.whereis(NervesGate.SSH)
  defp current_pid(:subnet_router), do: Process.whereis(NervesGate.SubnetRouter)
  defp current_pid(:cluster), do: Process.whereis(NervesGate.Cluster)
  defp current_pid(:configuration), do: Process.whereis(NervesGate.Gateway.Configuration)
  defp current_pid(:dependencies), do: Process.whereis(NervesGate.Dependencies)
  defp current_pid(:alarms), do: Process.whereis(NervesGate.Alarms.Runtime)

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end

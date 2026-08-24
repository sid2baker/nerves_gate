defmodule NervesGateQEMU.StatusTest do
  use ExUnit.Case, async: true

  alias NervesGateQEMU.Status

  test "projects the versioned canonical gateway status schema" do
    projected = Status.project_gateway(device(), :running, :up, :none, gateway_status())

    assert projected.configured
    assert projected.internet == :online
    assert projected.tailnet == :online
    assert projected.cluster == :offline
    assert projected.tailnet_ip == "100.64.0.10"
    assert projected.daemon == "running"
    assert projected.replicas == 2
    assert projected.connected_replicas == 1
    assert projected.stale_replicas == 1
    assert projected.alarms == [%{"id" => "cluster_unavailable"}]
    assert projected.error == nil
  end

  test "rejects unknown gateway status schemas" do
    projected = Status.project_gateway(device(), :running, :up, :none, %{"schema" => "old"})
    assert projected.error == :unsupported_status_schema
    assert projected.internet == :unknown
  end

  defp device do
    %{
      id: "M01",
      slug: "m01",
      port: 4001,
      iframe_url: "http://m01.localhost:4001",
      status_url: "http://127.0.0.1:4001/api/status"
    }
  end

  defp gateway_status do
    %{
      "schema" => "nerves_gate.status.v1",
      "configuration" => %{"configured" => true},
      "local" => %{
        "data" => %{
          "internet" => %{"status" => "online"},
          "tailnet" => %{"status" => "online", "ipv4" => "100.64.0.10"},
          "cluster" => %{"status" => "blocked"},
          "alarms" => [%{"id" => "cluster_unavailable"}]
        }
      },
      "replicas" => %{
        "gate-a" => %{"connected" => true},
        "gate-b" => %{"connected" => false}
      },
      "runtime" => %{"tailscale" => %{"daemon" => "running"}}
    }
  end
end

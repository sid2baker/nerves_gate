defmodule NervesGateQEMU.StatusTest do
  use ExUnit.Case, async: true

  alias NervesGateQEMU.Status

  test "projects the versioned canonical gateway status schema" do
    projected = Status.project_gateway(device(), :running, :up, :none, gateway_status())

    assert projected.configured
    assert projected.internet == :online
    assert projected.tailnet == :online
    assert projected.cluster == :blocked
    assert projected.tailnet_ip == "100.64.0.10"
    assert projected.daemon == "running"
    assert projected.replicas == 2
    assert projected.connected_replicas == 1
    assert projected.stale_replicas == 1
    assert projected.alarms == [%{"id" => "cluster_unavailable"}]
    assert projected.error == nil
  end

  test "preserves explicit disabled and unconfigured subsystem states" do
    status =
      gateway_status()
      |> put_in(["local", "state", "configuration", "configured"], false)
      |> put_in(["local", "state", "internet", "state"], "unconfigured")
      |> put_in(["local", "state", "cluster", "state"], "disabled")

    projected = Status.project_gateway(device(), :running, :up, :none, status)

    assert projected.internet == :unconfigured
    assert projected.cluster == :disabled
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
      "schema" => "nerves_gate.status.v3",
      "local" => %{
        "state" => %{
          "configuration" => %{"configured" => true},
          "internet" => %{"state" => "online"},
          "tailnet" => %{
            "state" => "online",
            "ipv4" => "100.64.0.10",
            "health" => %{"daemon" => "running"}
          },
          "cluster" => %{"state" => "blocked"},
          "alarms" => [%{"id" => "cluster_unavailable"}]
        }
      },
      "replicas" => %{
        "gate-a" => %{"connected" => true},
        "gate-b" => %{"connected" => false}
      }
    }
  end
end

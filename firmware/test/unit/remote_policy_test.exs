defmodule NervesGate.RemotePolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.Remote.Policy
  test "auth keys are validated, transient and sanitized", do: assert_auth_keys()
  test "HTTPS Serve waits for an enrolled and usable identity", do: assert_serve_policy()

  test "only connect requires synchronized system time" do
    remote = %{Policy.unavailable() | available: true}

    assert {:error,
            %{
              code: "time_unsynchronized",
              message: "Waiting for system time synchronization."
            }} = Policy.available(remote, :connect)

    assert :ok = Policy.available(%{remote | time_synchronized: true}, :connect)

    for operation <- [:configure, :disconnect] do
      assert :ok = Policy.available(remote, operation)
    end

    assert {:error, %{code: "time_unsynchronized"}} =
             Policy.available(Map.delete(remote, :time_synchronized), :connect)

    assert {:error, %{code: "remote_unavailable"}} =
             Policy.available(Policy.unavailable(), :connect)

    assert {:error, %{code: "remote_busy"}} =
             Policy.available(%{remote | operation: "connect"}, :connect)
  end

  defp assert_auth_keys do
    assert {:ok, %{hostname: "gateway", auth_key: "test-key"}} =
             Policy.validate(:connect, %{"hostname" => "GATEWAY", "auth_key" => "test-key"})

    for key <- [nil, "", "   ", [], String.duplicate("x", 4097)] do
      assert {:error, %{code: "invalid_parameters"}} =
               Policy.validate(:connect, %{"hostname" => "gateway", "auth_key" => key})
    end

    assert {:error, _} =
             Policy.validate(:configure, %{"hostname" => "gateway", "auth_key" => "test-key"})

    assert {:error, _} =
             Policy.validate(:connect, %{
               "hostname" => "gateway",
               "auth_key" => "test-key",
               "extra" => true
             })

    assert %{health: ["Failed [private key]"]} =
             Policy.sanitize(%{health: ["Failed tskey-auth-test-key"]})

    refute Map.has_key?(Policy.sanitize(%{auth_key: "test-key"}), :auth_key)

    assert :ok = Policy.expected(%{hostname: nil}, :any)
    assert :ok = Policy.expected(%{hostname: nil}, nil)
    assert :ok = Policy.expected(%{hostname: "gateway"}, "gateway")
    assert {:error, %{code: "stale_remote"}} = Policy.expected(%{hostname: "renamed"}, "gateway")
  end

  defp assert_serve_policy do
    ready = %{
      Policy.unavailable()
      | available: true,
        state: "online",
        auth_state: "authenticated",
        dns_name: "gateway.example.ts.net"
    }

    assert Policy.serve_dns_name(ready, nil) == ready.dns_name
    assert Policy.serve_dns_name(ready, ready.dns_name) == nil
    renamed = %{ready | dns_name: "renamed.example.ts.net"}
    assert Policy.serve_dns_name(renamed, ready.dns_name) == renamed.dns_name

    for pending <- [
          Policy.unavailable(),
          %{ready | available: false},
          %{ready | state: "offline"},
          %{ready | auth_state: "authenticating"},
          %{ready | auth_state: "needs_approval"},
          %{ready | auth_state: "stopped"},
          %{ready | dns_name: nil},
          %{ready | dns_name: ""},
          %{ready | error: %{code: "remote_failed", message: "Failed"}}
        ] do
      assert Policy.serve_dns_name(pending, nil) == nil
    end

    for operation <- ["connect", "configure", "disconnect", "sharing_enable", "serve"] do
      assert Policy.serve_dns_name(%{ready | operation: operation}, nil) == nil
    end
  end
end

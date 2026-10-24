defmodule NervesGate.RemotePolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.Remote.Policy
  test "auth keys are validated, transient and sanitized", do: assert_auth_keys()
  test "HTTPS Serve waits for an enrolled and usable identity", do: assert_serve_policy()

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

defmodule NervesGateSim.TailnetAuth do
  @moduledoc "Test auth keys and enrollment for simulator-owned QEMU guests."

  def auth_key do
    case System.get_env("TAILSCALED_TEST_AUTH_KEY") do
      nil -> Tailscaled.Testing.auth_key()
      "" -> {:error, "TAILSCALED_TEST_AUTH_KEY is empty"}
      key -> {:ok, key}
    end
  end

  # Never pass a credential-bearing result to an assertion or diagnostic.
  def enroll(vm, hostname) do
    case auth_key() do
      {:ok, key} -> connect(vm, hostname, key)
      {:error, message} -> raise "Tailscale test auth key: #{message}"
    end
  end

  defp connect(vm, hostname, key) do
    result = :erpc.call(vm.node, NervesGate, :remote_connect, [hostname, [auth_key: key]], 15_000)
    unless result == :ok, do: raise("Guest rejected authentication admission.")
    :ok
  catch
    _, _ -> raise "Guest enrollment failed; inspect sanitized device status. No key was replayed."
  end
end

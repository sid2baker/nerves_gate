defmodule NervesGateSim.Scenarios.TailscaleAuth do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGateSim.ScenarioHelpers
  alias NervesGateSim.{Simulator, TailnetAuth}
  alias NervesGateSim.Simulator.Network
  alias NervesGateSim.TestQemu, as: Qemu

  def spec,
    do: %{
      name: "opt-in: three real tailnet enrollments, peer HTTP and identity after reboot",
      devices: :all,
      fresh_disk: true,
      opt_in: true
    }

  def run(%{devices: devices}) do
    assert map_size(devices) == 3, "tailscale_auth requires the dedicated three-device config"
    prefix = "ng-test-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    IO.puts("Tailscale test nodes: #{prefix}-[1-3]")
    guests = devices |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    enrolled =
      guests
      |> Enum.with_index(1)
      |> Enum.map(fn {vm, index} ->
        :ok = Simulator.network(vm, Network.defaults())
        save(vm, settings("eth0"))
        Qemu.await(vm, "#{vm.id}: Internet reachable for enrollment", &internet?/1, 60_000)
        Qemu.await(vm, "#{vm.id}: Tailscale ready", & &1.actions["remote.connect"].enabled)
        name = "#{prefix}-#{index}"
        Qemu.on_exit({vm.id, :tailnet}, fn -> logout(vm) end)
        TailnetAuth.enroll(vm, name)

        status =
          Qemu.await(
            vm,
            "#{vm.id}: real Tailscale authentication",
            fn status -> online?(status) and status.remote_access.hostname == name end,
            60_000
          )

        address = status.remote_access.ipv4
        assert tailnet_address?(address), "Authenticated guest has no Tailscale IPv4 address"
        registration = registration(vm)
        %{vm: vm, address: address, registration: registration}
      end)

    assert MapSet.size(MapSet.new(enrolled, & &1.address)) == 3
    assert MapSet.size(MapSet.new(enrolled, & &1.registration)) == 3
    peer_http(enrolled)

    first = hd(enrolled)
    Qemu.power_cycle(first.vm)

    Qemu.await(
      first.vm,
      "Tailscale identity reconnects after guest power cycle",
      fn status ->
        online?(status) and status.remote_access.ipv4 == first.address
      end,
      90_000
    )

    assert registration(first.vm) == first.registration
    peer_http(enrolled)
  end

  defp logout(vm) do
    assert :ok = :erpc.call(vm.node, Tailscaled, :logout, [], 10_000)

    Qemu.await(vm, "#{vm.id}: Tailscale logged out", fn status ->
      not online?(status) and status.remote_access.auth_state == "needs_login"
    end)
  end

  defp online?(status),
    do:
      status.remote_access.state == "online" and
        status.remote_access.auth_state == "authenticated"

  defp tailnet_address?(address) when is_binary(address) do
    match?(
      {:ok, {100, second, _, _}} when second in 64..127,
      :inet.parse_ipv4_address(String.to_charlist(address))
    )
  end

  defp tailnet_address?(_), do: false

  defp registration(vm) do
    Qemu.await(vm, "#{vm.id}: tagged Tailscale identity", fn _ -> is_binary(node_id(vm)) end)
    id = node_id(vm)
    assert is_binary(id), "The test node identity disappeared"
    id
  end

  # Read only our guest's daemon. Never assert on raw status: it can contain a login URL.
  defp node_id(vm) do
    socket = :erpc.call(vm.node, Application, :fetch_env!, [:tailscaled_ex, :socket], 5_000)

    case :erpc.call(
           vm.node,
           Tailscaled.LocalAPI,
           :request,
           [[socket: socket], "GET", "status?peers=false"],
           7_000
         ) do
      {:ok, %{"Self" => %{"ID" => id, "Online" => true, "Tags" => tags}}, _}
      when is_binary(id) and is_list(tags) ->
        if "tag:ci" in tags, do: id

      _ ->
        nil
    end
  catch
    :error, {:erpc, _} -> nil
  end

  defp peer_http(enrolled) do
    for source <- enrolled, target <- enrolled, source.vm.id != target.vm.id do
      Qemu.await(
        source.vm,
        "#{source.vm.id} reaches #{target.vm.id} over tailnet HTTP",
        fn _ ->
          reachable?(source.vm, target.address)
        end,
        60_000
      )
    end
  end

  # The request originates inside the guest and targets only another owned guest's
  # Tailscale address. Host forwards, DNS and public HTTP cannot satisfy this check.
  # Return a boolean, never a response body containing the gateway's CSRF token.
  defp reachable?(vm, address) do
    result =
      :erpc.call(
        vm.node,
        :httpc,
        :request,
        [
          :get,
          {String.to_charlist("http://#{address}:4000/"), [{~c"connection", ~c"close"}]},
          [timeout: 5_000, connect_timeout: 3_000, autoredirect: false],
          [body_format: :binary]
        ],
        7_000
      )

    case result do
      {:ok, {{_, 200, _}, _, body}} -> is_binary(body) and byte_size(body) > 0
      _ -> false
    end
  catch
    :error, {:erpc, _} -> false
  end
end

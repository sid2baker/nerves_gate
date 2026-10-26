defmodule NervesGate.Network.Local do
  @moduledoc "Application-owned, isolated IPv4 links and durable subnet-advertisement cleanup."
  import Bitwise
  alias NervesGate.{Config, Error, Remote}
  alias NervesGate.Network.{Policy, Subnet, Vintage}

  def candidate(status, interface, address, prefix) do
    with :ok <- Policy.available(status),
         %{"network" => %{"mode" => "ports"} = network} <- status.config,
         %{"role" => "application", "address" => nil} <- network[interface],
         true <- interface in ["eth0", "eth1"] and is_integer(prefix) and prefix in 1..30,
         {:ok, address} <-
           Config.validate_address(%{
             "ip_method" => "static",
             "static_ip" => address,
             "subnet_mask" => mask(prefix),
             "gateway" => nil
           }),
         %{ports: ports} <- status.observed,
         %{present: true, state: :configured, master: nil, addresses: []} <-
           Enum.find(ports, &(&1.name == interface)),
         {:ok, scope} <- Subnet.build(interface, address),
         :ok <- no_overlap(status, scope) do
      {:ok, scope}
    else
      {:error, _} = error ->
        error

      _ ->
        failure(
          "local_unavailable",
          "Enable an independent, unaddressed Ethernet interface for applications first. Internet, joined and USB links cannot be claimed."
        )
    end
  end

  def address(scope),
    do: %{
      "ip_method" => "static",
      "static_ip" => scope.address,
      "subnet_mask" => mask(scope.prefix),
      "gateway" => nil
    }

  defp mask(prefix) do
    <<a, b, c, d>> = <<0xFFFFFFFF <<< (32 - prefix)::32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp no_overlap(status, scope) do
    observed = status.observed

    others =
      Enum.reject(observed.ports, &(&1.name == scope.interface)) ++
        Enum.reject([observed.bridge, observed.usb, Map.get(observed, :cellular)], &is_nil/1) ++
        Map.get(observed, :management, [])

    saved =
      for {name, %{"address" => %{"ip_method" => "static"} = address}} <-
            Config.ports(status.config["network"]),
          name != scope.interface,
          do: %{
            address: address["static_ip"],
            prefix_length: elem(Config.prefix_length(address["subnet_mask"]), 1)
          }

    # Tailnet management addresses must never become an application subnet.
    protected = [%{address: "100.64.0.0", prefix_length: 10}]
    addresses = protected ++ saved ++ Enum.flat_map(others, & &1.addresses)

    if Enum.any?(
         addresses,
         &Config.overlap?(scope.address, scope.prefix, &1.address, &1.prefix_length)
       ),
       do:
         failure(
           "local_overlap",
           "The requested subnet overlaps Internet, another local interface, cellular, USB or protected management addressing."
         ),
       else: :ok
  end

  def ready?(nil, _), do: false

  def ready?(scope, %{observed: %{ports: ports}} = status) do
    case Enum.find(ports, &(&1.name == scope.interface)) do
      %{present: true, link: true, state: :configured, master: nil, addresses: addresses} ->
        Enum.any?(addresses, &(&1.address == scope.address and &1.prefix_length == scope.prefix)) and
          no_overlap(status, scope) == :ok

      _ ->
        false
    end
  end

  def ready?(_, _), do: false

  def reserve(scope) do
    with {:ok, nil} <- read(),
         :ok <- write(scope, false),
         do: Vintage.apply_local(scope.interface, address(scope))
  end

  # Called inside Remote's serialized read-before-write boundary, not before
  # admission. A route already advertised by someone else is never adopted.
  def mark_advertising(scope) do
    case read() do
      {:ok, %{scope: ^scope, route_owned: false}} -> write(scope, true)
      _ -> {:error, :route_ownership_unavailable}
    end
  end

  def advertise(scope),
    do: Remote.sharing(:sharing_claim, %{scope: scope, route: scope.cidr})

  def cleanup(scope) do
    with {:ok, %{scope: ^scope, route_owned: owned}} <- read(),
         :ok <- withdraw(scope, owned),
         :ok <- Vintage.apply_local(scope.interface, nil),
         :ok <- File.rm(path()) do
      :ok
    else
      _ ->
        failure(
          "local_cleanup_required",
          "Local resource cleanup is incomplete. Its journal is retained; inspect state before explicitly recovering it."
        )
    end
  end

  defp withdraw(_, false), do: :ok

  defp withdraw(scope, true) do
    case Remote.sharing(:sharing_disable, %{scope: scope, route: scope.cidr}) do
      {:ok, routes} -> if scope.cidr in routes, do: {:error, :still_advertised}, else: :ok
      error -> error
    end
  end

  def cleanup_ready? do
    case read() do
      {:ok, %{route_owned: false}} -> true
      {:ok, %{route_owned: true}} -> match?(%{available: true, operation: nil}, Remote.status())
      _ -> false
    end
  end

  def load do
    case read() do
      {:ok, nil} ->
        nil

      {:ok, %{scope: scope}} ->
        lease(scope, nil, :cleanup_pending)

      _ ->
        %{
          lease(nil, nil, :blocked)
          | error:
              Error.new(
                "local_journal_invalid",
                "Local resource ownership could not be read. Application access is blocked; inspect the persistent journal and Tailscale routes."
              )
        }
    end
  end

  def lease(scope, owner, phase),
    do: %{scope: scope, owner: owner, monitor: nil, ref: nil, phase: phase, error: nil}

  def action_allowed(:release_local, _, _), do: :ok

  def action_allowed(:advertise_local, %{phase: :configured, scope: scope}, status) do
    if ready?(scope, status),
      do: :ok,
      else:
        failure(
          "local_not_ready",
          "The claimed address, independent topology and physical link must be ready before advertising."
        )
  end

  def action_allowed(_, _, _),
    do:
      failure(
        "local_outcome_unknown",
        "Inspect the claim and release it before attempting another advertisement."
      )

  def cleanup_if_ready(scope) do
    if cleanup_ready?(), do: cleanup(scope), else: :deferred
  end

  def complete(local, :release, :deferred), do: {%{local | phase: :cleanup_pending}, :ok}

  def complete(local, action, :ok), do: completed(local, action)
  def complete(local, action, {:ok, routes}) when is_list(routes), do: completed(local, action)

  def complete(local, _, _), do: failed(local)
  defp completed(_, :release), do: {nil, :ok}

  defp completed(local, action) do
    phase = next_phase(local.owner, action)
    response = if action == :claim, do: {:ok, local.ref}, else: :ok
    {%{local | phase: phase}, response}
  end

  defp next_phase(nil, _), do: :cleanup_pending
  defp next_phase(_, :claim), do: :configured
  defp next_phase(_, _), do: :advertised

  defp failed(local) do
    {:error, error} =
      failure(
        "local_outcome_unknown",
        "Local access did not complete safely. Inspect its status; release or explicitly recover it before trying again."
      )

    {%{local | phase: :blocked, error: error}, {:error, error}}
  end

  def observation(%{owner: pid} = local, pid, status, remote) when is_pid(pid) do
    scope = local.scope

    %NervesGateSDK.Network.Local{
      ref: local.ref,
      interface: scope.interface,
      address: scope.address,
      prefix: scope.prefix,
      subnet: scope.cidr,
      phase: local.phase,
      ready?: ready?(scope, status),
      approval: :unknown,
      advertised?: advertised?(remote, scope.cidr),
      error: local.error && local.error.code
    }
  end

  def observation(_, _, _, _), do: nil

  defp advertised?(%{advertised_routes: routes}, cidr) when is_list(routes), do: cidr in routes
  defp advertised?(_, _), do: nil

  def public(nil), do: nil

  def public(local),
    do: %{interface: local.scope && local.scope.interface, phase: local.phase, error: local.error}

  def owned(%{owner: pid, ref: ref}, pid, ref) when is_pid(pid) and is_reference(ref), do: :ok

  def owned(_, _, _),
    do: failure("not_owner", "This process does not own the local network claim.")

  def idle(nil), do: :ok

  def idle(_),
    do:
      failure(
        "local_in_use",
        "Release application network access and finish its cleanup before changing platform networking."
      )

  def read do
    case File.read(path()) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, bytes} when byte_size(bytes) < 4096 -> decode(bytes)
      _ -> {:error, :invalid_journal}
    end
  end

  defp decode(bytes) do
    with {:ok,
          %{
            "interface" => interface,
            "address" => address,
            "prefix" => prefix,
            "route_owned" => owned
          } = record} <- Jason.decode(bytes),
         true <-
           map_size(record) == 4 and interface in ["eth0", "eth1"] and is_boolean(owned) and
             is_integer(prefix) and prefix in 1..30,
         {:ok, normalized} <-
           Config.validate_address(%{
             "ip_method" => "static",
             "static_ip" => address,
             "subnet_mask" => mask(prefix),
             "gateway" => nil
           }),
         {:ok, scope} <- Subnet.build(interface, normalized) do
      {:ok, %{scope: scope, route_owned: owned}}
    else
      _ -> {:error, :invalid_journal}
    end
  end

  defp write(scope, owned) do
    bytes =
      Jason.encode!(%{
        interface: scope.interface,
        address: scope.address,
        prefix: scope.prefix,
        route_owned: owned
      })

    with :ok <- File.mkdir_p(Path.dirname(path())),
         {:ok, file} <- File.open(path(), [:write, :binary, :sync]) do
      try do
        with :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp path,
    do:
      Application.get_env(
        :nerves_gate,
        :local_network_journal,
        "/data/nerves_gate/local_network.json"
      )

  defp failure(code, message), do: {:error, Error.new(code, message)}
end

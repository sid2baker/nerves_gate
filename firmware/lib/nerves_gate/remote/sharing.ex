defmodule NervesGate.Remote.Sharing do
  @moduledoc "Pure admission and route changes for process-owned IPv4 application leases."
  alias NervesGate.Network.Subnet
  alias NervesGate.Remote.Policy

  def scope(%{config: %{"network" => %{"mode" => "ports"}}} = status),
    do: Subnet.from_status(status)

  def scope(_),
    do:
      {:error,
       %{
         code: "sharing_dedicated_only",
         message:
           "Sharing requires a configured application lease. Internet and USB cannot be advertised."
       }}

  def known(%{sharing: %{uncertain: [], ready: true}}), do: :ok

  def known(_),
    do:
      {:error,
       %{
         code: "sharing_unknown",
         message:
           "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
       }}

  # External advertisements may also depend on the LAN. Do not guess which ones
  # are safe to leave behind during a role/subnet change. Rollback is independent.
  def lan_change(remote) do
    with :ok <- known(remote),
         :ok <- Policy.available(remote),
         routes when is_list(routes) <- remote.advertised_routes do
      if routes == [],
        do: :ok,
        else:
          {:error,
           %{
             code: "sharing_active",
             message:
               "Release application network access before changing LAN settings. Remove any other subnet advertisements in Tailscale as well."
           }}
    else
      _ ->
        {:error,
         %{
           code: "sharing_unknown",
           message:
             "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
         }}
    end
  end

  def change(:sharing_sync, _, routes) when is_list(routes), do: {:ok, routes}

  def change(:sharing_claim, %{route: route, scope: %{cidr: route}}, routes)
      when is_binary(route) and is_list(routes) do
    if route in routes,
      do:
        {:error,
         %{
           code: "route_in_use",
           message:
             "This subnet is already advertised. Existing advertisements cannot be adopted by an application."
         }},
      else: {:ok, Enum.sort(Enum.uniq(routes ++ [route]))}
  end

  def change(:sharing_disable, %{route: route, scope: %{cidr: route}}, routes)
      when is_binary(route) and is_list(routes),
      do: {:ok, List.delete(routes, route)}

  def change(_, _, _),
    do:
      {:error,
       %{
         code: "sharing_unknown",
         message:
           "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
       }}
end

defmodule NervesGate.Remote.Sharing do
  @moduledoc "Pure admission and route changes for the confirmed IPv4 equipment subnet."
  alias NervesGate.Equipment.Subnet
  alias NervesGate.Remote.Policy

  def scope(%{config: %{"network" => %{"mode" => "ports"}}} = status),
    do: Subnet.from_status(status)

  def scope(_), do: {:error, :sharing_dedicated_only}

  def enable(status, remote) do
    with :ok <- Policy.available(remote),
         :ok <- known(remote),
         {:ok, scope} <- scope(status),
         {:ok, ^scope} <- Subnet.active(status) do
      {:ok, %{scope: scope, route: scope.cidr}}
    end
  end

  # Turning sharing off must still work when the equipment cable is disconnected.
  def disable(status, remote) do
    with :ok <- Policy.available(remote), {:ok, scope} <- scope(status) do
      {:ok, %{scope: scope, route: scope.cidr}}
    end
  end

  def known(%{sharing: %{uncertain: [], ready: true}}), do: :ok
  def known(_), do: {:error, :sharing_unknown}

  # External advertisements may also depend on the LAN. Do not guess which ones
  # are safe to leave behind during a role/subnet change. Rollback is independent.
  def lan_change(remote) do
    with :ok <- known(remote),
         :ok <- Policy.available(remote),
         routes when is_list(routes) <- remote.advertised_routes do
      if routes == [], do: :ok, else: {:error, :sharing_active}
    else
      _ -> {:error, :sharing_unknown}
    end
  end

  def change(:sharing_sync, _, routes) when is_list(routes), do: {:ok, routes}

  def change(:sharing_enable, %{route: route, scope: %{cidr: route}}, routes)
      when is_binary(route) and is_list(routes),
      do: {:ok, Enum.sort(Enum.uniq(routes ++ [route]))}

  def change(:sharing_disable, %{route: route, scope: %{cidr: route}}, routes)
      when is_binary(route) and is_list(routes),
      do: {:ok, List.delete(routes, route)}

  def change(_, _, _), do: {:error, :sharing_unknown}
end

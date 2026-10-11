defmodule NervesGate.Remote.Routes do
  @moduledoc false
  alias NervesGate.Remote.Sharing

  def change(:sharing_sync, _, routes) when is_list(routes), do: {:ok, routes}

  def change(:sharing_enable, %{route: route, scope: scope}, routes) when is_list(routes) do
    next = Enum.sort(Enum.uniq(routes ++ [route]))

    with {:ok, _} <- Sharing.decode(route),
         :ok <- Sharing.validate_routes(next, scope) do
      {:ok, next}
    end
  end

  def change(:sharing_disable, %{route: route}, routes) when is_list(routes) do
    with {:ok, _} <- Sharing.decode(route) do
      {:ok, Enum.sort(List.delete(routes, route))}
    end
  end

  def change(_, _, _), do: {:error, :sharing_unknown}
end

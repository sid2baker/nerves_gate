defmodule NervesGateWeb.ConfigureController do
  @moduledoc "Small HTTP surface for the three setup operations."

  use NervesGateWeb, :controller

  alias NervesGate.Setup

  def internet(connection, params) do
    respond(connection, Setup.configure_internet(params))
  end

  def tailscale(connection, params) do
    token = Map.get(params, "auth_token") || Map.get(params, "auth_key")
    respond(connection, Setup.configure_tailscale(token))
  end

  def cluster(connection, params) do
    cookie = get_in(params, ["cluster", "cookie"]) || Map.get(params, "cookie")
    respond(connection, Setup.configure_cluster(blank_to_nil(cookie)))
  end

  defp respond(connection, {:ok, phase}) do
    json(connection, %{ok: true, phase: phase})
  end

  defp respond(connection, {:error, reason}) do
    status =
      if reason in [:internet_required, :tailscale_offline, :tailscale_not_ready],
        do: 409,
        else: 422

    connection
    |> put_status(status)
    |> json(%{ok: false, error: public_error(reason)})
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(reason) when is_map(reason), do: reason
  defp public_error(_reason), do: :configuration_failed
end

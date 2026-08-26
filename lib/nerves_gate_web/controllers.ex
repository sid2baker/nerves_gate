defmodule NervesGateWeb.StatusController do
  @moduledoc false
  use NervesGateWeb, :controller

  def show(connection, _params) do
    with_session(connection, &NervesGate.status/1)
  end

  defp with_session(connection, function) do
    case NervesGate.connect() do
      {:ok, session, _state} ->
        try do
          json(connection, function.(session))
        after
          NervesGate.disconnect(session)
        end

      {:error, _reason} ->
        connection |> put_status(:service_unavailable) |> json(%{error: "state unavailable"})
    end
  end
end

defmodule NervesGateWeb.DiscoveryController do
  @moduledoc "Tailnet-only public metadata used for gateway group discovery."

  use NervesGateWeb, :controller

  def show(connection, _params) do
    case NervesGate.connect() do
      {:ok, session, _state} ->
        try do
          json(connection, NervesGate.discovery(session))
        after
          NervesGate.disconnect(session)
        end

      {:error, _reason} ->
        connection |> put_status(:service_unavailable) |> json(%{error: "state unavailable"})
    end
  end
end

defmodule NervesGateWeb.ConfigurationController do
  @moduledoc "Local commissioning transport for the public NervesGate command API."

  use NervesGateWeb, :controller

  alias NervesGateWeb.LocalAccess

  def internet(connection, params) do
    command_result(
      connection,
      NervesGate.stage_internet(
        Map.take(params, ["device", "internet"]),
        Map.get(params, "connection_id", command_id()),
        nil
      )
    )
  end

  def tailnet(connection, %{"candidate_id" => id} = params) do
    command_result(connection, NervesGate.stage_tailnet(id, Map.take(params, ["auth_token"])))
  end

  def tailnet(connection, _params), do: command_result(connection, {:error, :candidate_required})

  def cluster(connection, %{"candidate_id" => id} = params) do
    command_result(connection, NervesGate.stage_cluster(id, Map.take(params, ["cluster"])))
  end

  def cluster(connection, _params), do: command_result(connection, {:error, :candidate_required})

  def confirm(connection, %{"candidate_id" => id}) do
    actor = %{id: command_id(), tailnet?: LocalAccess.tailnet?(connection.remote_ip)}
    command_result(connection, NervesGate.confirm(id, actor))
  end

  def confirm(connection, _params), do: command_result(connection, {:error, :candidate_required})

  defp command_result(connection, :ok), do: json(connection, %{ok: true})
  defp command_result(connection, {:ok, _value}), do: json(connection, %{ok: true})

  defp command_result(connection, {:error, reason}) do
    connection
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, error: inspect(reason)})
  end

  defp command_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

defmodule NervesGateWeb.ErrorHTML do
  @moduledoc false
  use NervesGateWeb, :html

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule NervesGateWeb.ErrorJSON do
  @moduledoc false

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end

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

  def update(connection, %{"scope" => scope} = params) do
    with {:ok, scope} <- settings_scope(scope),
         timeout when is_integer(timeout) and timeout > 0 <- Map.get(params, "timeout", 60_000) do
      command_result(
        connection,
        NervesGate.update_settings(
          scope,
          Map.drop(params, ["scope", "timeout", "connection_id"]),
          Map.get(params, "connection_id", command_id()),
          timeout
        )
      )
    else
      _invalid -> command_result(connection, {:error, :invalid_settings_update})
    end
  end

  def keep(connection, %{"candidate_id" => id}) do
    actor = %{id: command_id(), tailnet?: LocalAccess.tailnet?(connection.remote_ip)}
    command_result(connection, NervesGate.keep_settings(id, actor))
  end

  def keep(connection, _params), do: command_result(connection, {:error, :candidate_required})

  defp command_result(connection, :ok), do: json(connection, %{ok: true})
  defp command_result(connection, {:ok, _value}), do: json(connection, %{ok: true})

  defp command_result(connection, {:error, reason}) do
    connection
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, error: inspect(reason)})
  end

  defp settings_scope("internet"), do: {:ok, :internet}
  defp settings_scope("tailnet"), do: {:ok, :tailnet}
  defp settings_scope("cluster"), do: {:ok, :cluster}
  defp settings_scope(_scope), do: {:error, :invalid_settings_scope}

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

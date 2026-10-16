defmodule NervesGateWeb.TestsController do
  use Phoenix.Controller, formats: [:json]

  def state(conn, _) do
    json(
      conn,
      Map.put(NervesGate.QemuTests.snapshot(), :csrf_token, Plug.CSRFProtection.get_csrf_token())
    )
  end

  def control(conn, params) do
    result =
      case params do
        %{"lifecycle" => action} -> NervesGate.QemuTests.lifecycle(action)
        %{"mode" => mode} -> NervesGate.QemuTests.mode(mode)
        %{"action" => action} -> NervesGate.QemuTests.manual(action)
        _ -> {:error, "Expected a lifecycle, mode or manual action"}
      end

    case result do
      :ok -> json(conn, %{ok: true})
      {:error, message} -> json(conn, %{error: message})
    end
  end

  def run(conn, %{"scenario" => scenario}) do
    case NervesGate.QemuTests.run(scenario) do
      {:ok, id} -> json(conn, %{id: id})
      {:error, message} -> json(conn, %{error: message})
    end
  end
end

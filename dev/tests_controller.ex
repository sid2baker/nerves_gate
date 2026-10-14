defmodule NervesGateWeb.TestsController do
  use Phoenix.Controller, formats: [:json]

  def state(conn, _) do
    json(
      conn,
      Map.put(NervesGate.QemuTests.snapshot(), :csrf_token, Plug.CSRFProtection.get_csrf_token())
    )
  end

  def run(conn, %{"scenario" => scenario}) do
    case NervesGate.QemuTests.run(scenario) do
      {:ok, id} -> json(conn, %{id: id})
      {:error, message} -> json(conn, %{error: message})
    end
  end
end

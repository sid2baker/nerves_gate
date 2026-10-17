defmodule NervesGateWeb.Simulator.Api do
  @moduledoc "JSON for mix test and mix dev.ui. Never includes device credentials."
  use Phoenix.Controller, formats: [:json]
  alias NervesGate.QemuTests

  def state(conn, _) do
    json(
      conn,
      Map.merge(QemuTests.snapshot(), %{
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
        # mix dev.ui must start its VM with the session's private EPMD port.
        epmd_port: String.to_integer(System.fetch_env!("ERL_EPMD_PORT"))
      })
    )
  end

  def control(conn, params) do
    result =
      case params do
        %{"lifecycle" => action} -> QemuTests.lifecycle(action)
        %{"device" => device, "mode" => mode} -> QemuTests.mode(device, mode)
        %{"device" => device, "action" => action} -> QemuTests.manual(device, action)
        _ -> {:error, "Expected a lifecycle action, or a device with a mode or manual action"}
      end

    reply(conn, result)
  end

  def run(conn, %{"device" => device, "scenario" => scenario}),
    do: reply(conn, QemuTests.run(device, scenario))

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:ok, id}), do: json(conn, %{id: id})
  defp reply(conn, {:error, message}), do: json(conn, %{error: message})
end

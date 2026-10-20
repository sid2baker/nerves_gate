defmodule NervesGateWeb.Simulator.Api do
  @moduledoc "JSON for the simulator CLI tasks. Never includes device credentials."
  use Phoenix.Controller, formats: [:json]
  alias NervesGate.QemuTests

  def state(conn, _) do
    json(
      conn,
      Map.merge(QemuTests.snapshot(), %{
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
        session_id: System.get_env("QEMU_SESSION_ID"),
        session_port: String.to_integer(System.fetch_env!("QEMU_HTTP_PORT")),
        # mix dev.ui must start its VM with the session's private EPMD port.
        epmd_port: String.to_integer(System.fetch_env!("ERL_EPMD_PORT"))
      })
    )
  end

  def control(conn, params) do
    result =
      case params do
        %{"session" => "stop", "session_id" => id} -> QemuTests.stop_session(id)
        %{"lifecycle" => action} -> QemuTests.lifecycle(action)
        %{"device" => device, "mode" => mode} -> QemuTests.mode(device, mode)
        %{"device" => device, "action" => action} -> QemuTests.manual(device, action)
        _ -> {:error, "Expected a lifecycle action, or a device with a mode or manual action"}
      end

    conn =
      if params["session"] == "stop", do: put_resp_header(conn, "connection", "close"), else: conn

    reply(conn, result)
  end

  def run(conn, %{"device" => device, "scenario" => scenario}),
    do: reply(conn, QemuTests.run(device, scenario))

  # Development install of a host-built package through the device's own
  # administration API. Reinstalling replaces the app's development copy;
  # its data directory is preserved.
  def install(conn, %{"device" => device, "package" => path}) do
    reply(conn, QemuTests.install(device, path))
  end

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:ok, id}) when is_integer(id), do: json(conn, %{id: id})
  defp reply(conn, {:error, message}) when is_binary(message), do: json(conn, %{error: message})
  defp reply(conn, {:error, reason}), do: json(conn, %{error: inspect(reason)})
end

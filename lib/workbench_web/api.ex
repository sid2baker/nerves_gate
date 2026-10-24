defmodule WorkbenchWeb.Api do
  @moduledoc "JSON for the simulator CLI tasks. Never includes device credentials."
  use Phoenix.Controller, formats: [:json]
  alias Scenarios.Runner

  def state(conn, _) do
    json(
      conn,
      Map.merge(Runner.snapshot(), %{
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
        applications: Workbench.Applications.list(),
        discovery: Workbench.LANDiscovery.snapshot(),
        operation: Workbench.Operations.snapshot(),
        session_id: System.get_env("WORKBENCH_SESSION_ID"),
        session_port: String.to_integer(System.fetch_env!("WORKBENCH_HTTP_PORT"))
      })
    )
  end

  def console(conn, %{"device" => device}) do
    case Runner.console(device) do
      {:ok, target} -> json(conn, target)
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
    end
  end

  def control(conn, params) do
    result =
      case params do
        %{"session" => "stop", "session_id" => id} -> Workbench.Operations.stop_session(id)
        %{"lifecycle" => action} -> Workbench.Operations.lifecycle(action)
        %{"device" => device, "mode" => mode} -> Runner.mode(device, mode)
        %{"device" => device, "action" => action} -> Runner.manual(device, action)
        _ -> {:error, "Expected a lifecycle action, or a device with a mode or manual action"}
      end

    conn =
      if params["session"] == "stop", do: put_resp_header(conn, "connection", "close"), else: conn

    reply(conn, result)
  end

  def review_firmware(conn, params), do: reply(conn, Workbench.Operations.review_firmware(params))

  def confirm_firmware(conn, params),
    do: reply(conn, Workbench.Operations.confirm_firmware(params["review_id"], params["address"]))

  def application(conn, %{"action" => "new", "path" => path}),
    do: reply(conn, Workbench.Applications.create(path))

  def application(conn, %{"action" => "open", "path" => path}),
    do: reply(conn, Workbench.Applications.open(path))

  def application(conn, _), do: reply(conn, {:error, "Expected new or open"})

  def operation(conn, params),
    do: reply(conn, Workbench.Operations.start(params["kind"], params["app"], params["device"]))

  def run(conn, %{"device" => device, "scenario" => scenario}),
    do: reply(conn, Runner.run(device, scenario))

  # Development install of a host-built package through the device's own
  # administration API. Reinstalling replaces the app's development copy;
  # its data directory is preserved.
  def install(conn, %{"device" => device, "package" => path}) do
    reply(conn, Runner.install(device, path))
  end

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:ok, id}) when is_integer(id), do: json(conn, %{id: id})
  defp reply(conn, {:ok, %{path: _, name: _} = app}), do: json(conn, %{ok: true, app: app})
  defp reply(conn, {:error, message}) when is_binary(message), do: json(conn, %{error: message})
  defp reply(conn, {:error, reason}), do: json(conn, %{error: inspect(reason)})
end

defmodule NervesGateWeb.Backend do
  @moduledoc """
  UI calls run locally in firmware, or on the runtime `:backend_node` in
  development. Commands have no local fallback or retries. Projection subscriptions
  call the device server directly, preserving the LiveView caller's identity.
  """
  @host Application.compile_env(:nerves_gate, :target) == :host

  def subscribe_projection, do: projection_call(:subscribe)

  def projection do
    case projection_call(:snapshot) do
      {:error, :unavailable} -> NervesGate.Projection.disconnected()
      projection -> projection
    end
  end

  defp projection_call(request) do
    request_projection(request)
  catch
    :exit, {_, {GenServer, :call, _}} -> {:error, :unavailable}
  end

  def status, do: call(:status, [])
  def distribution_cookie, do: call(:distribution_cookie, [])
  def network_confirm(id), do: call(:network_confirm, [id])
  def network_cancel(id), do: call(:network_cancel, [id])
  def remote_connect(name), do: call(:remote_connect, [name])
  def remote_configure(name), do: call(:remote_configure, [name])
  def remote_disconnect, do: call(:remote_disconnect, [])
  def remote_login_url, do: call(:remote_login_url, [])
  def identify, do: call(:identify, [])
  def equipment_scan, do: call(:equipment_scan, [])
  def equipment_label(id, label), do: call(:equipment_label, [id, label])
  def equipment_share, do: call(:equipment_share, [])
  def equipment_unshare, do: call(:equipment_unshare, [])
  def bus_configure(port, params), do: call(:bus_configure, [port, params])
  def bus_capture(port), do: call(:bus_capture, [port])
  def modbus_read(port, params), do: call(:modbus_read, [port, params])

  def network_propose(settings, opts \\ []) do
    # Workstation HTTP addresses cannot prove USB access to the device.
    opts = if @host, do: Keyword.delete(opts, :access), else: opts
    call(:network_propose, [settings, opts])
  end

  if @host do
    defp request_projection(request) do
      case Application.get_env(:nerves_gate, :backend_node) do
        nil -> {:error, :unavailable}
        node -> GenServer.call({NervesGate.ProjectionServer, node}, request)
      end
    end

    defp call(function, args) do
      case Application.get_env(:nerves_gate, :backend_node) do
        nil -> unavailable(function)
        node -> :erpc.call(node, NervesGate, function, args, 5_000)
      end
    catch
      :error, {:erpc, reason} when reason in [:noconnection, :timeout] -> unavailable(function)
    end

    defp unavailable(:status), do: NervesGate.Status.disconnected()

    defp unavailable(function) when function in [:remote_login_url, :distribution_cookie],
      do: {:error, %{code: "backend_disconnected", message: "The device did not reply."}}

    defp unavailable(_) do
      {:error,
       %{
         code: "outcome_unknown",
         message:
           "The device did not reply. The command may have run; read status before retrying."
       }}
    end
  else
    defp request_projection(request), do: GenServer.call(NervesGate.ProjectionServer, request)

    defp call(function, args), do: apply(NervesGate, function, args)
  end
end

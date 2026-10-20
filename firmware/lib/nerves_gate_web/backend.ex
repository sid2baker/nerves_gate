defmodule NervesGateWeb.Backend do
  @moduledoc """
  UI calls use the configured `:backend_node`: `:local` for device services,
  a node name for remote services, or nil while disconnected. Commands have no
  local fallback or retries. Projection subscriptions call the device server
  directly, preserving the LiveView caller's identity. The simulator site
  observes each device by passing its node explicitly.
  """

  def configured, do: Application.get_env(:nerves_gate, :backend_node)

  def subscribe_projection(backend \\ configured()), do: projection_call(:subscribe, backend)

  def projection(backend \\ configured()) do
    case projection_call(:snapshot, backend) do
      {:error, :unavailable} -> NervesGate.Projection.disconnected()
      projection -> projection
    end
  end

  defp projection_call(request, backend) do
    case backend do
      :local -> GenServer.call(NervesGate.ProjectionServer, request)
      nil -> {:error, :unavailable}
      node -> GenServer.call({NervesGate.ProjectionServer, node}, request)
    end
  catch
    :exit, {_, {GenServer, :call, _}} -> {:error, :unavailable}
  end

  def distribution_cookie, do: call(:distribution_cookie, [])
  def network_confirm(id), do: call(:network_confirm, [id])
  def network_cancel(id), do: call(:network_cancel, [id])
  def remote_connect(name, opts \\ []), do: call(:remote_connect, [name, opts])
  def remote_configure(name, opts \\ []), do: call(:remote_configure, [name, opts])
  def remote_disconnect, do: call(:remote_disconnect, [])

  def remote_login_url(backend \\ configured()) do
    call(:remote_login_url, [], backend)
  end

  def storage_setup(action, card_id \\ nil, confirmation \\ nil),
    do: call(:storage_setup, [action, card_id, confirmation])

  def identify, do: call(:identify, [])
  def ssh_add_key(key), do: call(:ssh_add_key, [key])
  def ssh_remove_key(fingerprint), do: call(:ssh_remove_key, [fingerprint])
  def equipment_scan, do: call(:equipment_scan, [])
  def equipment_label(id, label), do: call(:equipment_label, [id, label])
  def equipment_share, do: call(:equipment_share, [])
  def equipment_unshare, do: call(:equipment_unshare, [])
  def bus_configure(port, params), do: call(:bus_configure, [port, params])
  def bus_capture(port), do: call(:bus_capture, [port])
  def modbus_read(port, params), do: call(:modbus_read, [port, params])

  def network_propose(settings, opts \\ []) do
    # Only the device's own HTTP socket can prove USB access. Never forward a
    # workstation's socket observations, even when both endpoints share a host.
    backend = configured()
    opts = if backend == :local, do: opts, else: Keyword.delete(opts, :access)
    call(:network_propose, [settings, opts], backend)
  end

  defp call(function, args, backend \\ configured()) do
    case backend do
      :local -> apply(NervesGate, function, args)
      nil -> unavailable(function)
      node -> :erpc.call(node, NervesGate, function, args, 5_000)
    end
  catch
    :error, {:erpc, reason} when reason in [:noconnection, :timeout] -> unavailable(function)
  end

  defp unavailable(function) when function in [:remote_login_url, :distribution_cookie],
    do: {:error, %{code: "backend_disconnected", message: "The device did not reply."}}

  defp unavailable(_) do
    {:error,
     %{
       code: "outcome_unknown",
       message: "The device did not reply. The command may have run; read status before retrying."
     }}
  end
end

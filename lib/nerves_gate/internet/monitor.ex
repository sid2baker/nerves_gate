defmodule NervesGate.Internet.Monitor do
  @moduledoc "Answers whether the device can use the Internet and retains detailed diagnostics."

  use GenServer

  alias NervesGate.Internet.Alarms
  alias NervesGate.Internet.Connectivity
  alias NervesGate.Internet.Manager

  @check_order [:physical_link, :ip_address, :default_route, :dns, :internet_https]

  defstruct [
    :timer,
    :last,
    :last_repair,
    interval: 10_000,
    repair_interval: 60_000,
    repair: &Manager.reapply/0,
    verifier: &Connectivity.verify/1
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    state = %__MODULE__{
      interval:
        Keyword.get(
          options,
          :interval,
          Application.get_env(:nerves_gate, :internet_poll_interval, 10_000)
        ),
      repair: Keyword.get(options, :repair, &Manager.reapply/0),
      repair_interval: Keyword.get(options, :repair_interval, 60_000),
      verifier: Keyword.get(options, :verifier, &Connectivity.verify/1)
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.last || offline(:starting), state}

  @impl true
  def handle_info(:poll, state) do
    result = current_result(state.verifier)
    state = maybe_repair(state, result)
    Alarms.report(result)

    if result != state.last do
      publish(result)
    end

    {:noreply, schedule(%{state | last: result, timer: nil}, state.interval)}
  end

  @spec summarize(String.t() | nil, map()) :: map()
  def summarize(nil, _checks), do: offline(:not_configured)

  def summarize(interface, checks) do
    online = Connectivity.internet_ready?(checks)

    %{
      interface: interface,
      online: online,
      ready: online,
      reason: if(online, do: nil, else: first_failure(checks)),
      checks: checks
    }
  end

  defp current_result(verifier) do
    case Manager.status().known_good do
      %{interface: interface} -> summarize(interface, verifier.(interface))
      nil -> offline(:not_configured)
    end
  catch
    :exit, _reason -> offline(:manager_unavailable)
  end

  defp first_failure(checks) do
    Enum.find_value(@check_order, :unknown, fn check ->
      case Map.get(checks, check) do
        :ok -> nil
        {:error, reason} -> normalize_reason(check, reason)
        _other -> check
      end
    end)
  end

  defp normalize_reason(:physical_link, reason), do: reason
  defp normalize_reason(:ip_address, reason), do: reason
  defp normalize_reason(:default_route, reason), do: reason
  defp normalize_reason(:dns, _reason), do: :dns_failure
  defp normalize_reason(:internet_https, _reason), do: :https_failure

  defp offline(reason) do
    %{interface: nil, online: false, ready: false, reason: reason, checks: %{}}
  end

  defp maybe_repair(state, %{reason: reason})
       when reason in [:no_ipv4_address, :missing_default_route] do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.last_repair) or now - state.last_repair >= state.repair_interval do
      safe_repair(state.repair)
      %{state | last_repair: now}
    else
      state
    end
  end

  defp maybe_repair(state, _result), do: state

  defp safe_repair(repair) do
    repair.()
  catch
    _kind, _reason -> :ok
  end

  defp publish(result) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "internet", {:internet_changed, result})
  end

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :poll, delay)}
end

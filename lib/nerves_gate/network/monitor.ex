defmodule NervesGate.Network.Monitor do
  @moduledoc "Continuously tracks link, address, route, DNS, and HTTPS as separate states."

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.Network.Connectivity
  alias NervesGate.Network.Manager

  defstruct [:timer, :last, interval: 10_000, verifier: &Connectivity.verify/1]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(options) do
    state = %__MODULE__{
      interval:
        Keyword.get(
          options,
          :interval,
          Application.get_env(:nerves_gate, :network_poll_interval, 10_000)
        ),
      verifier: Keyword.get(options, :verifier, &Connectivity.verify/1)
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.last || %{}, state}

  @impl true
  def handle_info(:poll, state) do
    result = current_result(state.verifier)

    if result != state.last do
      publish(result)
    end

    {:noreply, schedule(%{state | last: result, timer: nil}, state.interval)}
  end

  defp current_result(verifier) do
    case Manager.status().known_good do
      %{interface: interface, method: method} ->
        checks = verifier.(interface)
        Alarms.report_connectivity(interface, checks, method)
        %{interface: interface, checks: checks, ready: Connectivity.internet_ready?(checks)}

      nil ->
        %{interface: nil, checks: %{}, ready: false}
    end
  catch
    :exit, _reason -> %{interface: nil, checks: %{}, ready: false}
  end

  defp publish(result) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "network_health", {:connectivity_changed, result})
  end

  defp schedule(state, delay), do: %{state | timer: Process.send_after(self(), :poll, delay)}
end

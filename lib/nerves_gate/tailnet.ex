defmodule NervesGate.Tailnet do
  @moduledoc """
  Observes and classifies the Tailscale daemon owned by `tailscale_ex`.

  This is deliberately a GenServer rather than a formal FSM: every observation
  is legal in every condition and the lifecycle is a pure classification of the
  latest typed Tailscale status.
  """

  use GenServer

  alias NervesGate.Tailnet.{Observation, Status}

  @poll_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    payload = Keyword.get_lazy(options, :payload, fn -> new(options) end)
    GenServer.start_link(__MODULE__, payload, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    health = Tailscale.Health.initial()

    %{
      phase: :connecting,
      observed: Observation.offline(:starting, health),
      source: Tailscale.Status.unknown(),
      health: health,
      read_status: Keyword.get(options, :read_status, &Tailscale.status/0),
      read_health: Keyword.get(options, :read_health, &Tailscale.health/0),
      read_routes: Keyword.get(options, :route_status, &Tailscale.route_status/0),
      publisher: Keyword.get(options, :publisher, &publish/1),
      last_error: nil
    }
  end

  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server \\ __MODULE__), do: call(server, :refresh)

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: refresh(server)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> Observation.offline(:unavailable)
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(state) do
    schedule_poll()
    publish_state(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = observe(state)
    publish_state(state)
    {:reply, observation_reply(state), state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:diagnostics, _from, state) do
    diagnostics = %{
      state: state.phase,
      desired: %{integrated: true},
      observed: state.observed,
      blocked_by: nil,
      last_error: state.last_error,
      attempt: 0,
      retry_at: nil
    }

    {:reply, diagnostics, state}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_poll()
    state = observe(state)
    publish_state(state)
    {:noreply, state}
  end

  defp observe(state) do
    {source, read_error} = read_status(state)
    health = read_health(state)

    routes =
      if source.online == true,
        do: Observation.route_status(state.read_routes, state.observed.subnet_router),
        else: Observation.unavailable_routes()

    observed = Observation.project(source, routes, health)
    phase = lifecycle(source, observed)

    %{
      state
      | source: source,
        health: health,
        phase: phase,
        observed: %{observed | state: phase},
        last_error: read_error
    }
  end

  defp read_status(state) do
    case safe_call(state.read_status) do
      {:ok, %Tailscale.Status{} = source} -> {source, nil}
      {:error, reason} -> {state.source, public_error(reason)}
      invalid -> {state.source, public_error(invalid)}
    end
  end

  defp read_health(state) do
    case safe_call(state.read_health) do
      {:ok, %Tailscale.Health{} = health} -> health
      _error -> state.health
    end
  end

  defp safe_call(function) do
    function.()
  catch
    _kind, reason -> {:error, reason}
  end

  defp lifecycle(source, observed) do
    cond do
      source.backend_state in [:needs_login, :needs_machine_auth] -> :needs_auth
      source.authenticated == false -> :needs_auth
      observed.online -> :online
      true -> :connecting
    end
  end

  defp observation_reply(%{last_error: nil}), do: :ok
  defp observation_reply(state), do: {:error, state.last_error}

  defp public_status(state) do
    state.observed
    |> Map.put(:state, state.phase)
    |> Map.update!(:health, &public_health/1)
  end

  defp publish_state(state), do: state.publisher.(public_status(state))
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)

  defp call(server, request) do
    GenServer.call(server, request, 15_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :tailnet, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Tailnet DeviceState publication failed: #{inspect(reason)}"
    end
  end

  defp public_health(%Tailscale.Health{} = health) do
    health
    |> Map.from_struct()
    |> Map.take([
      :client,
      :daemon,
      :socket,
      :authenticated,
      :online,
      :restart_attempt,
      :transitioned_at
    ])
    |> Map.update(:transitioned_at, nil, fn
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      value -> value
    end)
  end

  defp public_health(health) when is_map(health), do: health
end

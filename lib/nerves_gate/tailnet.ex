defmodule NervesGate.Tailnet do
  @moduledoc """
  Lifecycle owner for observed Tailnet state.

  Tailscale daemon lifecycle remains owned by `tailscale_ex`. This machine
  serializes bounded status observations and publishes one typed public slice
  only after each observation transition commits.
  """

  alias NervesGate.FSM.{Diagnostics, Effect}
  alias NervesGate.Tailnet.{Observation, Status}

  @fsm """
  [*] --> disabled : boot
  disabled --> observing : enable
  disabled --> disabled : disable
  disabled --> disabled : tick
  disabled --> disabled : refresh
  disabled --> disabled : heal
  needs_auth --> observing : enable
  needs_auth --> disabled : disable
  needs_auth --> observing : tick
  needs_auth --> observing : refresh
  needs_auth --> observing : heal
  connecting --> observing : enable
  connecting --> disabled : disable
  connecting --> observing : tick
  connecting --> observing : refresh
  connecting --> observing : heal
  online --> observing : enable
  online --> disabled : disable
  online --> observing : tick
  online --> observing : refresh
  online --> observing : heal
  observing --> observing : enable
  observing --> observing : disable
  observing --> observing : tick
  observing --> observing : refresh
  observing --> observing : heal
  observing --> disabled : observation_completed
  observing --> observing : observation_completed
  observing --> needs_auth : observation_completed
  observing --> connecting : observation_completed
  observing --> online : observation_completed
  disabled --> [*] : terminate
  needs_auth --> [*] : terminate
  connecting --> [*] : terminate
  online --> [*] : terminate
  observing --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @type command :: :enable | :disable | :refresh | :heal
  @type event :: :tick | {:observation_completed, reference(), term()}
  @type input :: command() | event()

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    enabled =
      Keyword.get(
        options,
        :enabled,
        Application.get_env(:nerves_gate, :tailscale_enabled, true)
      )

    health = Tailscale.Health.initial()

    Diagnostics.new(%{
      owner: __MODULE__,
      desired: %{enabled: enabled, command_id: nil},
      observed: Observation.offline(if(enabled, do: :starting, else: :disabled), health),
      source: Tailscale.Status.unknown(),
      health: health,
      read_status: Keyword.get(options, :read_status, &Tailscale.status/0),
      read_health: Keyword.get(options, :read_health, &Tailscale.health/0),
      read_routes: Keyword.get(options, :route_status, &Tailscale.route_status/0),
      publisher: Keyword.get(options, :publisher, &publish/1),
      effect_timeout: Keyword.get(options, :effect_timeout, 10_000),
      generation: 0,
      effect: nil,
      last_result: nil
    })
  end

  @spec enable(GenServer.server()) :: :ok | {:error, term()}
  def enable(server \\ __MODULE__), do: Diagnostics.command(server, :enable, %{}, 15_000)

  @spec disable(GenServer.server()) :: :ok | {:error, term()}
  def disable(server \\ __MODULE__), do: Diagnostics.command(server, :disable, %{}, 15_000)

  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server \\ __MODULE__), do: Diagnostics.command(server, :refresh, %{}, 15_000)

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: Diagnostics.command(server, :heal, %{}, 15_000)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} ->
        public_status(state, payload.observed)

      nil ->
        Observation.offline(:unavailable)
    end
  end

  @spec actor_for_ip(String.t(), GenServer.server()) :: map()
  def actor_for_ip(ip, server \\ __MODULE__) do
    peer = Enum.find(status(server).peers, &(&1.ipv4 == ip))
    %{ip: ip, name: (peer && peer.hostname) || "tailnet user"}
  catch
    :exit, _reason -> %{ip: ip, name: "tailnet user"}
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    payload =
      if payload.desired.enabled,
        do: payload,
        else: %{payload | observed: Observation.offline(:disabled, payload.health)}

    finish(:*, :boot, :disabled, payload)
  end

  def on_transition(state, :enable, command, payload) do
    payload = set_desired(payload, true, command.id)

    if state == :observing,
      do: finish(state, :enable, :observing, payload),
      else: begin_observation(state, :enable, payload)
  end

  def on_transition(:observing, :disable, command, payload) do
    payload = set_desired(payload, false, command.id)
    finish(:observing, :disable, :observing, payload)
  end

  def on_transition(state, :disable, command, payload) do
    payload =
      payload
      |> set_desired(false, command.id)
      |> Map.put(:observed, Observation.offline(:disabled, payload.health))
      |> result(command.id, :ok)

    finish(state, :disable, :disabled, payload, error: nil, blocked_by: nil)
  end

  def on_transition(:disabled, event, command, payload) when event in [:refresh, :heal] do
    if payload.desired.enabled do
      desired = Map.put(payload.desired, :command_id, command.id)
      begin_observation(:disabled, event, %{payload | desired: desired})
    else
      finish(:disabled, event, :disabled, result(payload, command.id, :ok))
    end
  end

  def on_transition(:disabled, :tick, _event_payload, payload) do
    if payload.desired.enabled,
      do: begin_observation(:disabled, :tick, payload),
      else: finish(:disabled, :tick, :disabled, payload)
  end

  def on_transition(:observing, event, command, payload) when event in [:refresh, :heal] do
    desired = Map.put(payload.desired, :command_id, command.id)
    finish(:observing, event, :observing, %{payload | desired: desired})
  end

  def on_transition(:observing, :tick, _event_payload, payload),
    do: finish(:observing, :tick, :observing, payload)

  def on_transition(state, event, command, payload) when event in [:refresh, :heal] do
    desired = Map.put(payload.desired, :command_id, command.id)
    begin_observation(state, event, %{payload | desired: desired})
  end

  def on_transition(state, :tick, _event_payload, payload),
    do: begin_observation(state, :tick, payload)

  def on_transition(
        :observing,
        :observation_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation}} = payload
      ) do
    payload = %{payload | effect: nil}
    complete_observation(outcome, generation, payload)
  end

  def on_transition(:observing, :observation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload.observed))
    launch_observation(state, payload)
  end

  defp launch_observation(:observing, %{effect: %{ref: ref, generation: generation}} = payload) do
    case Effect.start(
           self(),
           ref,
           fn -> observe_runtime(payload, generation) end,
           fn ref, outcome -> {:observation_completed, {ref, outcome}} end,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Tailnet observation launch failed: #{inspect(reason)}"
    end
  end

  defp launch_observation(_state, _payload), do: :ok

  defp observe_runtime(payload, generation) do
    {source, read_error} = read_status(payload)
    health = read_health(payload)

    routes =
      if source.online == true,
        do: Observation.route_status(payload.read_routes, payload.observed.subnet_router),
        else: Observation.unavailable_routes()

    {generation, source, read_error, health, routes}
  end

  defp complete_observation(
         {:returned, {generation, source, read_error, health, routes}},
         generation,
         payload
       ) do
    payload = %{payload | source: source, health: health}

    if payload.desired.enabled do
      observed = Observation.project(source, routes, health)
      to = lifecycle_state(source, observed)
      observed = %{observed | state: to}
      command_id = payload.desired.command_id

      payload =
        payload
        |> Map.put(:observed, observed)
        |> result(command_id, observation_result(read_error))

      finish(:observing, :observation_completed, to, payload,
        reason: read_error || observed.error,
        error: read_error,
        blocked_by: nil,
        attempt: 0,
        retry_at: nil
      )
    else
      observed = Observation.offline(:disabled, health)
      command_id = payload.desired.command_id
      payload = payload |> Map.put(:observed, observed) |> result(command_id, :ok)
      finish(:observing, :observation_completed, :disabled, payload)
    end
  end

  defp complete_observation(
         {:returned, {_old_generation, _source, _error, _health, _routes}},
         _generation,
         payload
       ) do
    if payload.desired.enabled do
      effect = %{ref: make_ref(), generation: payload.generation}
      finish(:observing, :observation_completed, :observing, %{payload | effect: effect})
    else
      observed = Observation.offline(:disabled, payload.health)
      payload = payload |> Map.put(:observed, observed) |> result(payload.desired.command_id, :ok)
      finish(:observing, :observation_completed, :disabled, payload)
    end
  end

  defp complete_observation(:timed_out, _generation, payload),
    do: observation_failed(payload, :tailnet_observation_timed_out)

  defp complete_observation(:cancelled, _generation, payload),
    do: observation_failed(payload, :tailnet_observation_cancelled)

  defp complete_observation({:crashed, _kind, _reason, _stack}, _generation, payload),
    do: observation_failed(payload, :tailnet_observation_crashed)

  defp complete_observation(_invalid, _generation, payload),
    do: observation_failed(payload, :invalid_tailnet_observation_result)

  defp observation_failed(payload, error) do
    observed = Observation.offline(error, payload.health)

    payload =
      payload
      |> Map.put(:observed, observed)
      |> result(payload.desired.command_id, {:error, error})

    finish(:observing, :observation_completed, :connecting, payload, reason: error, error: error)
  end

  defp read_status(payload) do
    case payload.read_status.() do
      {:ok, %Tailscale.Status{} = source} -> {source, nil}
      {:error, reason} -> {payload.source, public_error(reason)}
      invalid -> {payload.source, {:invalid_status_result, public_error(invalid)}}
    end
  end

  defp read_health(payload) do
    case payload.read_health.() do
      {:ok, %Tailscale.Health{} = health} -> health
      _error -> payload.health
    end
  end

  defp lifecycle_state(source, observed) do
    cond do
      source.backend_state in [:needs_login, :needs_machine_auth] -> :needs_auth
      source.authenticated == false -> :needs_auth
      observed.online -> :online
      true -> :connecting
    end
  end

  defp set_desired(payload, enabled, command_id) do
    desired = %{enabled: enabled, command_id: command_id}

    if payload.desired.enabled == enabled,
      do: %{payload | desired: desired},
      else: %{payload | desired: desired, generation: payload.generation + 1}
  end

  defp begin_observation(from, event, payload) do
    effect = %{ref: make_ref(), generation: payload.generation}
    finish(from, event, :observing, %{payload | effect: effect})
  end

  defp result(payload, id, value) do
    if is_nil(id), do: payload, else: %{payload | last_result: {id, value}}
  end

  defp observation_result(nil), do: :ok
  defp observation_result(error), do: {:error, error}

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp public_status(state, observed) do
    public_state = if state == :observing, do: observed.state, else: state

    observed
    |> with_state(public_state)
    |> Map.update!(:health, &public_health/1)
  end

  defp with_state(%Status{} = status, state), do: %{status | state: state}
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

defmodule NervesGate.Tailnet.Address do
  @moduledoc "Validates concrete IPv4 addresses from Tailscale's 100.64.0.0/10 range."

  @spec parse_ipv4(String.t()) :: {:ok, :inet.ip4_address()} | :error
  def parse_ipv4(address) when is_binary(address) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, parsed} -> if(ipv4?(parsed), do: {:ok, parsed}, else: :error)
      {:error, _reason} -> :error
    end
  end

  def parse_ipv4(_address), do: :error

  @spec ipv4?(term()) :: boolean()
  def ipv4?({100, second, third, fourth}) do
    second in 64..127 and third in 0..255 and fourth in 0..255
  end

  def ipv4?(_address), do: false
end

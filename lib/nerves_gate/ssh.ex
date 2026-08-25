defmodule NervesGate.SSH.Status do
  @moduledoc "Secret-free public SSH lifecycle state."

  @enforce_keys [:enabled, :state, :address, :port]
  defstruct [
    :enabled,
    :state,
    :address,
    :port,
    :applied_change_id,
    :failed_change_id
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          state: :disabled | :blocked | :reconciling | :listening | :backoff,
          address: String.t() | nil,
          port: 22,
          applied_change_id: String.t() | nil,
          failed_change_id: String.t() | nil
        }
end

defmodule NervesGate.SSH do
  @moduledoc """
  Lifecycle and mutation owner for the Tailnet-only NervesSSH listener.

  Commands express intent; Tailnet and runtime completions are private events.
  Listener mutations are serialized through one correlated reconciliation
  effect. Desired changes during that effect are coalesced and reconciled after
  the active generation terminates.
  """

  alias NervesGate.FSM.{Diagnostics, Effect}
  alias NervesGate.Gateway.Configuration
  alias NervesGate.SSH.{Runtime, Status}

  @fsm """
  [*] --> disabled : boot
  disabled --> disabled : disable
  disabled --> disabled : heal
  disabled --> disabled : retry_timer_fired
  disabled --> disabled : tailnet_state_changed
  disabled --> blocked : enable
  disabled --> reconciling : enable
  blocked --> disabled : disable
  blocked --> blocked : enable
  blocked --> blocked : heal
  blocked --> blocked : retry_timer_fired
  blocked --> blocked : tailnet_state_changed
  blocked --> reconciling : enable
  blocked --> reconciling : heal
  blocked --> reconciling : retry_timer_fired
  blocked --> reconciling : tailnet_state_changed
  listening --> disabled : disable
  listening --> blocked : retry_timer_fired
  listening --> blocked : tailnet_state_changed
  listening --> listening : enable
  listening --> listening : heal
  listening --> listening : retry_timer_fired
  listening --> listening : tailnet_state_changed
  listening --> reconciling : disable
  listening --> reconciling : enable
  listening --> reconciling : heal
  listening --> reconciling : retry_timer_fired
  listening --> reconciling : tailnet_state_changed
  backoff --> disabled : disable
  backoff --> blocked : retry_timer_fired
  backoff --> blocked : tailnet_state_changed
  backoff --> backoff : enable
  backoff --> backoff : retry_timer_fired
  backoff --> reconciling : enable
  backoff --> reconciling : heal
  backoff --> reconciling : retry_timer_fired
  backoff --> reconciling : tailnet_state_changed
  reconciling --> reconciling : enable
  reconciling --> reconciling : disable
  reconciling --> reconciling : heal
  reconciling --> reconciling : retry_timer_fired
  reconciling --> reconciling : tailnet_state_changed
  reconciling --> reconciling : reconciliation_completed
  reconciling --> disabled : reconciliation_completed
  reconciling --> blocked : reconciliation_completed
  reconciling --> listening : reconciliation_completed
  reconciling --> backoff : reconciliation_completed
  disabled --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @retry_delay 1_000

  @type command :: :enable | :disable | :heal
  @type event ::
          :retry_timer_fired
          | {:tailnet_state_changed, map()}
          | {:reconciliation_completed, reference(), term()}
  @type input :: command() | event()

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    runtime = %{
      address: Keyword.get(options, :address, &Runtime.address/1),
      valid?: Keyword.get(options, :valid?, &Runtime.listener_valid?/2),
      start: Keyword.get(options, :starter, &Runtime.start/1),
      stop: Keyword.get(options, :stopper, &Runtime.stop/1),
      observe: Keyword.get(options, :observer, &Runtime.observe/1),
      port: Keyword.get(options, :port, Runtime.port())
    }

    Diagnostics.new(%{
      owner: __MODULE__,
      desired: %{enabled: Keyword.get(options, :enabled, false), change_id: nil},
      observed: %{listener: nil, tailnet: Keyword.get(options, :initial_tailnet)},
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      runtime: runtime,
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      effect_timeout: Keyword.get(options, :effect_timeout, 30_000),
      generation: 0,
      effect: nil,
      applied_change_id: nil,
      failed_change_id: nil,
      published: nil
    })
  end

  @spec enable() :: :ok | {:error, term()}
  def enable, do: Configuration.configure_ssh(true)

  @spec disable() :: :ok | {:error, term()}
  def disable, do: Configuration.configure_ssh(false)

  @spec set_enabled(boolean(), GenServer.server(), keyword()) :: :ok | {:error, term()}
  def set_enabled(enabled, server \\ __MODULE__, options \\ []) when is_boolean(enabled) do
    event = if enabled, do: :enable, else: :disable
    transition_result(server, event, %{change_id: Keyword.get(options, :change_id)})
  end

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: transition_result(server, :heal)

  @spec tailnet_state_changed(map(), GenServer.server()) :: :ok
  def tailnet_state_changed(status, server \\ __MODULE__) when is_map(status) do
    GenServer.cast(server, {:tailnet_state_changed, status})
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{} = state ->
        public_status(state.current, state.payload)

      nil ->
        %Status{
          enabled: false,
          state: :disabled,
          address: nil,
          port: Runtime.port(),
          applied_change_id: nil,
          failed_change_id: nil
        }
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    payload = refresh_tailnet(payload)
    finish(:*, :boot, :disabled, payload)
  end

  def on_transition(state, :enable, event_payload, payload) do
    payload = set_desired(payload, true, event_payload.change_id)
    reconcile_or_resolve(state, :enable, payload)
  end

  def on_transition(state, :disable, event_payload, payload) do
    payload = set_desired(payload, false, event_payload.change_id)
    reconcile_or_resolve(state, :disable, payload)
  end

  def on_transition(state, :heal, _event_payload, payload) do
    reconcile_or_resolve(state, :heal, payload, force: state != :disabled)
  end

  def on_transition(state, :tailnet_state_changed, status, payload) do
    payload = put_tailnet(payload, status)
    reconcile_or_resolve(state, :tailnet_state_changed, payload)
  end

  def on_transition(:reconciling, :retry_timer_fired, _event_payload, payload),
    do: finish(:reconciling, :retry_timer_fired, :reconciling, payload)

  def on_transition(state, :retry_timer_fired, _event_payload, payload) do
    payload = refresh_tailnet(payload)
    force = state == :backoff and retry_due?(payload)
    reconcile_or_resolve(state, :retry_timer_fired, payload, force: force)
  end

  def on_transition(
        :reconciling,
        :reconciliation_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation}} = payload
      ) do
    payload = %{payload | effect: nil}
    handle_reconciliation(outcome, generation, payload)
  end

  def on_transition(:reconciling, :reconciliation_completed, {_stale_ref, _outcome}, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :retry_timer_fired, payload}

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: payload}) do
    case payload.observed.listener do
      %{pid: pid} -> payload.runtime.stop.(pid)
      nil -> :ok
    end

    :ok
  end

  @doc false
  @spec after_transition(atom(), map()) :: :ok
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload))
    launch_reconciliation(state, payload)
  end

  defp launch_reconciliation(
         :reconciling,
         %{effect: %{ref: ref, generation: generation}} = payload
       ) do
    case Effect.start(
           self(),
           ref,
           fn -> reconcile_runtime(payload, generation) end,
           &reconciliation_event/2,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "SSH effect launch failed: #{inspect(reason)}"
    end
  end

  defp launch_reconciliation(_state, _payload), do: :ok

  defp reconciliation_event(ref, outcome), do: {:reconciliation_completed, {ref, outcome}}

  defp reconcile_runtime(payload, generation) do
    address = tailnet_address(payload)
    actual = payload.observed.listener || payload.runtime.observe.(address)

    result =
      cond do
        not payload.desired.enabled ->
          stop_actual(payload, actual)
          {:ok, nil}

        is_nil(address) ->
          stop_actual(payload, actual)
          {:blocked, :tailnet}

        payload.runtime.valid?.(actual, address) ->
          {:ok, actual}

        true ->
          stop_actual(payload, actual)

          case payload.runtime.start.(address) do
            {:ok, pid} when is_pid(pid) -> {:ok, %{pid: pid, address: address}}
            {:error, reason} -> {:error, reason}
            invalid -> {:error, {:invalid_listener_start_result, invalid}}
          end
      end

    {generation, result}
  end

  defp stop_actual(_payload, nil), do: :ok
  defp stop_actual(payload, %{pid: pid}), do: payload.runtime.stop.(pid)

  defp handle_reconciliation({:returned, {generation, result}}, generation, payload) do
    payload = apply_runtime_result(payload, result)

    if generation == payload.generation do
      resolve_after_result(payload, result)
    else
      payload
      |> begin_effect()
      |> then(&finish(:reconciling, :reconciliation_completed, :reconciling, &1))
    end
  end

  defp handle_reconciliation(:timed_out, _generation, payload),
    do: enter_backoff(payload, :listener_reconciliation_timed_out)

  defp handle_reconciliation(:cancelled, _generation, payload),
    do: enter_backoff(payload, :listener_reconciliation_cancelled)

  defp handle_reconciliation({:crashed, _kind, reason, _stack}, _generation, payload),
    do: enter_backoff(payload, {:listener_reconciliation_crashed, public_error(reason)})

  defp handle_reconciliation(_invalid, _generation, payload),
    do: enter_backoff(payload, :invalid_listener_reconciliation_result)

  defp apply_runtime_result(payload, {:ok, listener}),
    do: put_in(payload, [:observed, :listener], listener)

  defp apply_runtime_result(payload, {:blocked, :tailnet}),
    do: put_in(payload, [:observed, :listener], nil)

  defp apply_runtime_result(payload, {:error, _reason}),
    do: put_in(payload, [:observed, :listener], nil)

  defp resolve_after_result(payload, {:ok, nil}) do
    payload = mark_applied(payload)

    finish(:reconciling, :reconciliation_completed, :disabled, payload,
      error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    )
  end

  defp resolve_after_result(payload, {:ok, _listener}) do
    payload = mark_applied(payload)

    finish(:reconciling, :reconciliation_completed, :listening, payload,
      error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    )
  end

  defp resolve_after_result(payload, {:blocked, :tailnet}) do
    payload = mark_applied(payload)

    finish(:reconciling, :reconciliation_completed, :blocked, payload,
      error: nil,
      blocked_by: :tailnet
    )
  end

  defp resolve_after_result(payload, {:error, reason}),
    do: enter_backoff(payload, {:listener_start_failed, public_error(reason)})

  defp reconcile_or_resolve(state, event, payload, options \\ [])

  defp reconcile_or_resolve(:reconciling, event, payload, _options),
    do: finish(:reconciling, event, :reconciling, payload)

  defp reconcile_or_resolve(state, event, payload, options) do
    force = Keyword.get(options, :force, false)
    listener = payload.observed.listener
    address = tailnet_address(payload)

    cond do
      disabled_without_listener?(payload, listener) ->
        finish(state, event, :disabled, mark_applied(payload), error: nil, blocked_by: nil)

      enabled_without_address?(payload, listener, address) ->
        finish(state, event, :blocked, mark_applied(payload), blocked_by: :tailnet)

      listener_already_matches?(payload, listener, address, force) ->
        finish(state, event, :listening, mark_applied(payload), error: nil, blocked_by: nil)

      waiting_for_retry?(state, payload, force) ->
        finish(state, event, :backoff, payload)

      true ->
        payload = begin_effect(payload)
        finish(state, event, :reconciling, payload, blocked_by: nil)
    end
  end

  defp disabled_without_listener?(payload, listener),
    do: not payload.desired.enabled and is_nil(listener)

  defp enabled_without_address?(payload, listener, address),
    do: payload.desired.enabled and is_nil(address) and is_nil(listener)

  defp listener_already_matches?(payload, listener, address, force),
    do: not force and listener_matches?(payload, listener, address)

  defp waiting_for_retry?(state, payload, force),
    do: state == :backoff and not force and not retry_due?(payload)

  defp begin_effect(payload) do
    %{payload | effect: %{ref: make_ref(), generation: payload.generation}}
  end

  defp set_desired(payload, enabled, change_id) do
    desired = %{enabled: enabled, change_id: change_id}

    if payload.desired.enabled == enabled do
      %{payload | desired: desired}
    else
      %{payload | desired: desired, generation: payload.generation + 1}
    end
  end

  defp put_tailnet(payload, status) do
    if payload.observed.tailnet == status do
      payload
    else
      payload
      |> put_in([:observed, :tailnet], status)
      |> Map.update!(:generation, &(&1 + 1))
    end
  end

  defp refresh_tailnet(payload) do
    put_tailnet(payload, payload.tailnet.())
  catch
    :exit, _reason -> payload
  end

  defp listener_matches?(_payload, nil, _address), do: false
  defp listener_matches?(_payload, _listener, nil), do: false

  defp listener_matches?(payload, listener, address),
    do: payload.runtime.valid?.(listener, address)

  defp tailnet_address(payload), do: payload.runtime.address.(payload.observed.tailnet || %{})

  defp enter_backoff(payload, error) do
    attempt = payload.attempt + 1
    payload = %{payload | failed_change_id: payload.desired.change_id}

    finish(:reconciling, :reconciliation_completed, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: now() + payload.retry_delay
    )
  end

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp public_status(state, payload) do
    listener = payload.observed.listener

    %Status{
      enabled: payload.desired.enabled,
      state: state,
      address: if(state == :listening and listener, do: encode_address(listener.address)),
      port: payload.runtime.port,
      applied_change_id: payload.applied_change_id,
      failed_change_id: payload.failed_change_id
    }
  end

  defp transition_result(server, event, payload \\ nil) do
    case Diagnostics.transition(server, event, payload) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_applied(payload) do
    %{
      payload
      | applied_change_id: payload.desired.change_id,
        failed_change_id: nil
    }
  end

  defp retry_due?(%{retry_at: nil}), do: true
  defp retry_due?(payload), do: now() >= payload.retry_at
  defp now, do: System.monotonic_time(:millisecond)
  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed
  defp encode_address(address), do: address |> :inet.ntoa() |> List.to_string()

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :ssh, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "SSH DeviceState publication failed: #{inspect(reason)}"
    end
  end
end

defmodule NervesGate.SSH.Runtime do
  @moduledoc "Idempotent NervesSSH listener operations for `NervesGate.SSH`."

  alias NervesGate.Storage
  alias NervesGate.Tailnet.Address
  alias NervesSSH.Options

  @port 22

  @spec address(map()) :: :inet.ip4_address() | nil
  def address(%{online: true, ipv4: ipv4}) when is_binary(ipv4) do
    case Address.parse_ipv4(ipv4) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  def address(_tailnet), do: nil

  @spec listener_valid?(map() | nil, :inet.ip4_address()) :: boolean()
  def listener_valid?(%{pid: pid, address: address}, address),
    do: is_pid(pid) and Process.alive?(pid)

  def listener_valid?(_listener, _address), do: false

  @spec observe(:inet.ip4_address() | nil) :: map() | nil
  def observe(nil), do: nil

  def observe(address) do
    NervesGate.SSH.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {NervesGate.SSH.Daemon, pid, _type, _modules} when is_pid(pid) ->
        %{pid: pid, address: address}

      _other ->
        nil
    end)
  catch
    :exit, _reason -> nil
  end

  @spec start(:inet.ip4_address()) :: {:ok, pid()} | {:error, term()}
  def start(address) do
    if Address.ipv4?(address) do
      options = options(address)

      child_spec = %{
        id: NervesGate.SSH.Daemon,
        start: {NervesSSH, :start_link, [options]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(NervesGate.SSH.DynamicSupervisor, child_spec) do
        {:ok, pid} -> verify_start(pid, options.name)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_tailnet_address}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(NervesGate.SSH.DynamicSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def stop(_pid), do: :ok

  @spec port() :: 22
  def port, do: @port

  defp verify_start(pid, name) do
    case daemon_info(name) do
      {:ok, _info} ->
        {:ok, pid}

      {:error, reason} ->
        stop(pid)
        {:error, reason}
    end
  end

  defp daemon_info(name) do
    NervesSSH.info(name)
  catch
    :exit, reason -> {:error, {:daemon_start_failed, reason}}
  end

  defp options(address) do
    Options.new(
      name: NervesGate.SSH.Daemon,
      authorized_keys: [],
      user_passwords: [],
      port: @port,
      subsystems: [],
      system_dir: Storage.path("nerves_ssh"),
      user_dir: Path.join(System.tmp_dir!(), "nerves_gate_ssh"),
      shell: :elixir,
      exec: :disabled,
      daemon_option_overrides: [inet: :inet, ip: address, no_auth_needed: true]
    )
    |> Options.sanitize()
  end
end

defmodule NervesGate.SSH.Supervisor do
  @moduledoc "Supervises the SSH lifecycle owner and its listener processes."

  use Supervisor

  alias NervesGate.SSH

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      {DynamicSupervisor, name: NervesGate.SSH.DynamicSupervisor, strategy: :one_for_one},
      {SSH, payload: SSH.new(), name: SSH}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 0, max_seconds: 1)
  end
end

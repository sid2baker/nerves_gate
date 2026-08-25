defmodule NervesGate.Commissioning.Status do
  @moduledoc "Secret-free public commissioning-access state."

  @enforce_keys [:state, :active, :mode]
  defstruct [:state, :active, :mode]

  @type t :: %__MODULE__{
          state: :disabled | :reconciling | :active | :waiting | :backoff,
          active: [map()],
          mode: :disabled | :commissioning
        }
end

defmodule NervesGate.Commissioning do
  @moduledoc """
  Lifecycle and mutation owner for temporary local commissioning interfaces.

  Interface mutations run only after entry into `:reconciling`. One correlated
  worker owns the active generation; newer desired state is coalesced and
  reconciled after that worker terminates.
  """

  alias NervesGate.Commissioning.{Access, Status}
  alias NervesGate.FSM.{Diagnostics, Effect, Retry}
  alias NervesGate.Internet.Hardware

  @fsm """
  [*] --> disabled : boot
  disabled --> reconciling : enable
  disabled --> reconciling : disable
  disabled --> disabled : heal
  disabled --> disabled : tick
  active --> reconciling : enable
  active --> reconciling : disable
  active --> reconciling : heal
  active --> reconciling : tick
  active --> active : release
  active --> waiting : release
  waiting --> reconciling : enable
  waiting --> reconciling : disable
  waiting --> reconciling : heal
  waiting --> reconciling : tick
  waiting --> waiting : release
  backoff --> reconciling : enable
  backoff --> reconciling : disable
  backoff --> reconciling : heal
  backoff --> reconciling : tick
  backoff --> backoff : tick
  reconciling --> reconciling : enable
  reconciling --> reconciling : disable
  reconciling --> reconciling : heal
  reconciling --> reconciling : tick
  reconciling --> reconciling : access_reconciliation_completed
  reconciling --> disabled : access_reconciliation_completed
  reconciling --> active : access_reconciliation_completed
  reconciling --> waiting : access_reconciliation_completed
  reconciling --> backoff : access_reconciliation_completed
  disabled --> [*] : terminate
  active --> [*] : terminate
  waiting --> [*] : terminate
  backoff --> [*] : terminate
  reconciling --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 2_000

  @retry_delay 2_000

  @type command :: {:enable, :commissioning, String.t() | nil} | :disable | :heal
  @type event ::
          :tick | {:release, String.t()} | {:access_reconciliation_completed, reference(), term()}
  @type input :: command() | event()

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    Diagnostics.new(%{
      owner: __MODULE__,
      desired: %{mode: :disabled, uplink: nil, command_id: nil, command: nil},
      observed: %{active: []},
      adapter:
        Keyword.get(options, :adapter, Application.fetch_env!(:nerves_gate, :internet_adapter)),
      hardware: Keyword.get(options, :hardware, &Hardware.interfaces/0),
      publisher: Keyword.get(options, :publisher, &publish/1),
      effect_timeout: Keyword.get(options, :effect_timeout, 15_000),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      generation: 0,
      effect: nil,
      last_result: nil
    })
  end

  @spec enable(:commissioning, String.t() | nil, GenServer.server()) ::
          {:ok, [map()]} | {:error, :no_interface | term()}
  def enable(mode, uplink \\ nil, server \\ __MODULE__) do
    Diagnostics.command(server, :enable, %{mode: mode, uplink: uplink}, 20_000)
  end

  @spec disable(GenServer.server()) :: :ok | {:error, term()}
  def disable(server \\ __MODULE__), do: Diagnostics.command(server, :disable, %{}, 20_000)

  @spec release(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def release(interface, server \\ __MODULE__), do: simple_transition(server, :release, interface)

  @spec heal(GenServer.server()) :: :ok | {:error, :no_interface | term()}
  def heal(server \\ __MODULE__), do: Diagnostics.command(server, :heal, %{}, 20_000)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} -> public_status(state, payload)
      nil -> %Status{state: :disabled, active: [], mode: :disabled}
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload),
    do: finish(:*, :boot, :disabled, payload)

  def on_transition(state, :enable, command, payload) do
    desired = %{
      mode: command.mode,
      uplink: command.uplink,
      command_id: command.id,
      command: :enable
    }

    payload = set_desired(payload, desired)

    if state == :reconciling,
      do: finish(state, :enable, :reconciling, expose_reconciliation(payload)),
      else: begin_reconciliation(state, :enable, payload)
  end

  def on_transition(state, :disable, command, payload) do
    desired = %{mode: :disabled, uplink: nil, command_id: command.id, command: :disable}
    payload = set_desired(payload, desired)

    if state == :reconciling,
      do: finish(state, :disable, :reconciling, expose_reconciliation(payload)),
      else: begin_reconciliation(state, :disable, payload)
  end

  def on_transition(:disabled, :heal, command, payload) do
    finish(:disabled, :heal, :disabled, result(payload, command.id, :ok))
  end

  def on_transition(:reconciling, :heal, _command, payload),
    do: finish(:reconciling, :heal, :reconciling, payload)

  def on_transition(state, :heal, command, payload) do
    desired = Map.merge(payload.desired, %{command_id: command.id, command: :heal})
    begin_reconciliation(state, :heal, %{payload | desired: desired})
  end

  def on_transition(state, :release, interface, payload) do
    active = Enum.reject(payload.observed.active, &(&1.interface == interface))
    payload = put_in(payload, [:observed, :active], active)
    to = if active == [], do: :waiting, else: state
    finish(state, :release, to, payload)
  end

  def on_transition(:reconciling, :tick, _event_payload, payload),
    do: finish(:reconciling, :tick, :reconciling, payload)

  def on_transition(:disabled, :tick, _event_payload, payload),
    do: finish(:disabled, :tick, :disabled, payload)

  def on_transition(:backoff, :tick, _event_payload, payload) do
    if Retry.due?(payload.retry_at),
      do: begin_reconciliation(:backoff, :tick, payload),
      else: finish(:backoff, :tick, :backoff, payload)
  end

  def on_transition(state, :tick, _event_payload, payload),
    do: begin_reconciliation(state, :tick, payload)

  def on_transition(
        :reconciling,
        :access_reconciliation_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation}} = payload
      ) do
    payload = %{payload | effect: nil}
    complete_reconciliation(outcome, generation, payload)
  end

  def on_transition(:reconciling, :access_reconciliation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  @doc false
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
           fn -> reconcile_access(payload, generation) end,
           fn ref, outcome -> {:access_reconciliation_completed, {ref, outcome}} end,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Commissioning effect launch failed: #{inspect(reason)}"
    end
  end

  defp launch_reconciliation(_state, _payload), do: :ok

  defp reconcile_access(payload, generation) do
    interfaces = payload.hardware.()

    result =
      case payload.desired.mode do
        :disabled ->
          Access.clear_all(
            payload.adapter,
            interfaces,
            payload.observed.active,
            payload.desired.uplink
          )

          {:ok, []}

        :commissioning ->
          Access.reconcile(
            payload.adapter,
            interfaces,
            payload.observed.active,
            payload.desired.uplink
          )
      end

    {generation, result}
  end

  defp complete_reconciliation({:returned, {generation, result}}, generation, payload) do
    if generation == payload.generation do
      resolve_result(result, payload)
    else
      payload
      |> begin_effect(:reconciling, :coalesced_change)
      |> then(&finish(:reconciling, :access_reconciliation_completed, :reconciling, &1))
    end
  end

  defp complete_reconciliation(:timed_out, _generation, payload),
    do: enter_backoff(payload, :commissioning_reconciliation_timed_out)

  defp complete_reconciliation(:cancelled, _generation, payload),
    do: enter_backoff(payload, :commissioning_reconciliation_cancelled)

  defp complete_reconciliation({:crashed, _kind, reason, _stack}, _generation, payload),
    do:
      enter_backoff(payload, {:commissioning_reconciliation_crashed, Retry.public_error(reason)})

  defp complete_reconciliation(_invalid, _generation, payload),
    do: enter_backoff(payload, :invalid_commissioning_reconciliation_result)

  defp resolve_result({:ok, active}, payload) do
    payload =
      payload
      |> put_in([:observed, :active], active)
      |> result(payload.desired.command_id, command_result(payload.desired.command, active))

    to = if payload.desired.mode == :disabled, do: :disabled, else: :active

    finish(:reconciling, :access_reconciliation_completed, to, payload,
      error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    )
  end

  defp resolve_result({:error, :no_interface}, payload) do
    payload =
      payload
      |> put_in([:observed, :active], [])
      |> result(payload.desired.command_id, {:error, :no_interface})

    finish(:reconciling, :access_reconciliation_completed, :waiting, payload,
      reason: :no_usable_interface,
      error: nil,
      blocked_by: :hardware
    )
  end

  defp resolve_result({:error, reason}, payload),
    do: enter_backoff(payload, {:commissioning_reconciliation_failed, Retry.public_error(reason)})

  defp resolve_result(invalid, payload),
    do: enter_backoff(payload, {:invalid_commissioning_result, Retry.public_error(invalid)})

  defp command_result(:enable, active), do: {:ok, active}
  defp command_result(:disable, _active), do: :ok
  defp command_result(:heal, _active), do: :ok
  defp command_result(nil, _active), do: :ok

  defp enter_backoff(payload, error) do
    attempt = payload.attempt + 1

    payload =
      result(payload, payload.desired.command_id, {:error, error})

    finish(:reconciling, :access_reconciliation_completed, :backoff, payload,
      reason: error,
      error: error,
      blocked_by: nil,
      attempt: attempt,
      retry_at: Retry.now() + payload.retry_delay
    )
  end

  defp set_desired(payload, desired) do
    if Map.take(payload.desired, [:mode, :uplink]) == Map.take(desired, [:mode, :uplink]) do
      %{payload | desired: desired}
    else
      %{payload | desired: desired, generation: payload.generation + 1}
    end
  end

  defp begin_reconciliation(from, event, payload) do
    payload = begin_effect(payload, from, event)
    finish(from, event, :reconciling, payload, blocked_by: nil)
  end

  defp begin_effect(payload, from, event) do
    effect = %{ref: make_ref(), generation: payload.generation, from: from, event: event}
    %{payload | effect: effect}
  end

  defp expose_reconciliation(%{effect: effect} = payload),
    do: %{payload | effect: %{effect | event: :coalesced_change}}

  defp result(payload, nil, _result), do: payload
  defp result(payload, id, result), do: %{payload | last_result: {id, result}}

  defp simple_transition(server, event, payload) do
    case Diagnostics.transition(server, event, payload) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp public_status(state, payload) do
    %Status{
      state: public_state(state, payload),
      active: payload.observed.active,
      mode: payload.desired.mode
    }
  end

  defp public_state(:reconciling, %{effect: %{from: from, event: event}})
       when event in [:tick, :heal],
       do: from

  defp public_state(state, _payload), do: state

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :commissioning, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Commissioning DeviceState publication failed: #{inspect(reason)}"
    end
  end
end

defmodule NervesGate.Commissioning.Access do
  @moduledoc "Pure commissioning-interface selection and idempotent runtime operations."

  alias NervesGate.Identity

  @spec reconcile(module(), [map()], [map()], String.t() | nil) ::
          {:ok, [map()]} | {:error, :no_interface}
  def reconcile(adapter, interfaces, active, uplink) do
    desired = desired_configurations(interfaces, uplink)

    if desired != [] and active == desired do
      {:ok, desired}
    else
      clear(adapter, active)

      case configure_available(desired, adapter) do
        [] -> {:error, :no_interface}
        configured -> {:ok, configured}
      end
    end
  end

  @spec clear_all(module(), [map()], [map()], String.t() | nil) :: :ok
  def clear_all(adapter, interfaces, active, uplink) do
    candidates =
      interfaces
      |> commissioning_candidates(uplink)
      |> Enum.map(&%{interface: &1.name})

    clear(adapter, Enum.uniq_by(active ++ candidates, & &1.interface))
  end

  @spec clear(module(), [map()]) :: :ok
  def clear(adapter, active) do
    Enum.each(active, &adapter.clear(&1.interface))
    :ok
  end

  @spec commissioning_candidates([map()], String.t() | nil) :: [map()]
  def commissioning_candidates(interfaces, uplink) do
    wifi = Enum.filter(interfaces, &(&1.kind == :wifi and &1.name != uplink))

    spare_ethernet =
      interfaces
      |> Enum.filter(&(&1.kind == :ethernet and &1.name != uplink and &1.name != "eth0"))
      |> Enum.sort_by(&ethernet_priority/1)

    wifi ++ spare_ethernet
  end

  defp ethernet_priority(%{name: "eth1"}), do: 0
  defp ethernet_priority(%{name: "eth2"}), do: 1
  defp ethernet_priority(%{name: name}), do: {2, name}

  defp desired_configurations(interfaces, uplink) do
    interfaces
    |> commissioning_candidates(uplink)
    |> Enum.with_index()
    |> Enum.map(fn {interface, index} ->
      interface
      |> commissioning_options(index)
      |> Map.put(:interface, interface.name)
    end)
  end

  defp configure_available(configurations, adapter) do
    Enum.filter(configurations, fn configuration ->
      %{interface: interface} = configuration
      options = Map.delete(configuration, :interface)
      adapter.configure_commissioning(interface, options) == :ok
    end)
  end

  defp commissioning_options(%{kind: kind}, index) do
    third_octet = 77 + index
    address = "192.168.#{third_octet}.1"

    %{
      kind: kind,
      address: address,
      prefix_length: 24,
      dhcp_start: "192.168.#{third_octet}.10",
      dhcp_end: "192.168.#{third_octet}.200",
      ssid: Identity.get().setup_ssid
    }
  end
end

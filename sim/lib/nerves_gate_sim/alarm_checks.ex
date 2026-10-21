defmodule NervesGateSim.AlarmChecks do
  @moduledoc "Bounded probes of the real guest Alarmist handler, without hardware adapters or mocks."
  alias NervesGate.Alarms

  @name __MODULE__

  def pulse(vm, fault, actions) do
    # This host-only helper is loaded only into the runner-owned, disposable guest.
    # Its RPC process owns the subscription and timers; none survive that process.
    {module, binary, path} = :code.get_object_code(__MODULE__)
    {:module, ^module} = :erpc.call(vm.node, :code, :load_binary, [module, path, binary], 5_000)
    :erpc.call(vm.node, __MODULE__, :collect, [fault, actions], 15_000)
  end

  @doc false
  def collect(fault, actions) do
    raw = {Alarms, @name, fault}
    managed = {Alarms.Warning, @name, fault}
    Alarms.register(@name, [fault])
    :ok = Alarmist.subscribe_all()
    tag = make_ref()

    try do
      for {after_ms, action} <- actions, do: Process.send_after(self(), {tag, action}, after_ms)
      deadline = now() + (actions |> List.last() |> elem(0)) + 2_500
      started = %{id: :probe_start, state: :start, level: :debug, at: now()}
      receive_events(tag, fault, [raw, managed], deadline, [started])
    after
      Alarms.report(fault, @name, false)
      # Barrier: the condition is clear before its rule and subscription disappear.
      Alarmist.managed_alarm_ids()
      Alarmist.remove_managed_alarm(managed)
      Alarmist.clear_alarm_level(raw)
      Alarmist.unsubscribe_all()
    end
  end

  defp receive_events(tag, fault, ids, deadline, events) do
    if now() >= deadline do
      Enum.reverse(events)
    else
      receive do
        {^tag, :register} ->
          NervesGate.Alarms.register(@name, [fault])
          receive_events(tag, fault, ids, deadline, events)

        {^tag, active} when is_boolean(active) or is_nil(active) ->
          NervesGate.Alarms.report(fault, @name, active)
          receive_events(tag, fault, ids, deadline, events)

        %Alarmist.Event{id: id, state: state, level: level, timestamp: at} ->
          events =
            if id in ids do
              [
                %{
                  id: id,
                  state: state,
                  level: level,
                  at: System.convert_time_unit(at, :native, :millisecond)
                }
                | events
              ]
            else
              events
            end

          receive_events(tag, fault, ids, deadline, events)
      after
        max(0, deadline - now()) -> Enum.reverse(events)
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

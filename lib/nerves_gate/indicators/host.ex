defmodule NervesGate.Indicators.Host do
  @moduledoc "In-memory LEDs, button and recovery preview. Never opens workstation devices."
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          values: %{run: 0, user1: 0, user2: 0},
          receiver: nil,
          read_error: [],
          write_error: [],
          writes: [],
          recoveries: [],
          recovery_result: :ok
        }
      end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  def read_led(led, server) do
    Agent.get(server, fn state ->
      if led in state.read_error,
        do: {:error, :led_unavailable},
        else: {:ok, Map.fetch!(state.values, led)}
    end)
  end

  def write_led(led, value, server) when value in [0, 1] do
    Agent.get_and_update(server, fn state ->
      if led in state.write_error do
        {{:error, :led_unavailable}, state}
      else
        {:ok,
         %{
           state
           | values: Map.put(state.values, led, value),
             writes: Enum.take([{led, value} | state.writes], 64)
         }}
      end
    end)
  end

  def open_button(receiver, server) do
    Agent.update(server, &%{&1 | receiver: receiver})
    {:ok, nil, "simulated:KEY_PROG1"}
  end

  @doc "Send a simulated key value: 1 press, 0 release, 2 repeat. Release once to arm after startup."
  def button(value, server \\ __MODULE__) when value in [0, 1, 2] do
    receiver = Agent.get(server, & &1.receiver)

    if is_pid(receiver),
      do: send(receiver, {:input_event, "simulated:KEY_PROG1", [{:ev_key, :key_prog1, value}]})

    :ok
  end

  @doc false
  def simulate(changes, server), do: Agent.update(server, &Map.merge(&1, changes))
  @doc false
  def snapshot(server), do: Agent.get(server, & &1)
end

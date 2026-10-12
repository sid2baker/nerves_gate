defmodule NervesGate.Recovery.Host do
  @moduledoc "Records simulated recovery in the LED preview Agent. Never reboots or deletes files."

  def execute(action, server) do
    Agent.get_and_update(server, fn
      %{recoveries: []} = state ->
        actions =
          if action == :factory_reset and state.recovery_result == :ok do
            [:factory_reset, :reboot]
          else
            [action]
          end

        {state.recovery_result, %{state | recoveries: actions}}

      state ->
        {{:error, :recovery_already_requested}, state}
    end)
  end
end

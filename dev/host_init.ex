defmodule NervesGate.HostInit do
  @moduledoc false

  # Launcher check, first in the workstation services. The workstation UI runs no
  # device services; it must have a remote backend or the owned simulator.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  def start_link(_) do
    if is_nil(Application.get_env(:nerves_gate, :backend_node)) and
         is_nil(Application.get_env(:nerves_gate, :simulator_node)),
       do:
         raise(
           "Host mode requires a device backend or owned simulator. Run mix dev.ec100 or mix dev."
         )

    unless Node.alive?(),
      do: raise("Start the remote UI with elixir --name <name@address> -S mix phx.server")

    :ignore
  end
end

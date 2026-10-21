defmodule Dev.GatewayInit do
  @moduledoc false

  # Launcher check, first in the workstation services. The workstation UI runs no
  # device services; mix dev.ui selects its device and starts distribution.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  def start_link(_) do
    if is_nil(Application.get_env(:nerves_gate, :backend_node)) or not Node.alive?(),
      do: raise("The workstation gateway UI needs a device. Run mix dev.ui.")

    :ignore
  end
end

defmodule NervesGate.Recovery do
  @moduledoc "Small recovery boundary, called only by Indicators' one-shot worker."

  def execute({module, context}, action) when action in [:reboot, :factory_reset],
    do: module.execute(action, context)

  def execute(_, _),
    do:
      {:error,
       %{code: "recovery_unavailable", message: "Recovery is unavailable on this target."}}
end

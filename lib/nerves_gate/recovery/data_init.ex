defmodule NervesGate.Recovery.DataInit do
  @moduledoc false

  # Nerves.Runtime's supported initialization hook. Run its normal formatter,
  # then fail startup if it silently returned :unmounted/:mounted_with_error.
  # The release starts nerves_runtime as :transient, before data users, so a
  # failure here stops boot instead of allowing writes to a missing data mount.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  if Mix.target() == :ec100 do
    def start_link(_) do
      Nerves.Runtime.Init.init_application_partition()

      with {:ok, _mount} <- NervesGate.Recovery.EC100.check_data() do
        :ignore
      end
    end
  else
    def start_link(_), do: {:error, :recovery_unavailable}
  end
end

defmodule NervesGate.Remote.Adapter do
  @moduledoc """
  Tailscale infrastructure boundary. Snapshot and enrollment URL reads must use
  cached observations; execute may block and is run in an owned, bounded worker.
  Stopping a worker cannot undo an already accepted daemon mutation.
  """
  @callback snapshot(term()) :: map()
  @callback execute(atom(), map(), term()) :: :ok | {:ok, String.t()} | {:error, term()}
  @callback login_url(term()) :: String.t() | nil
  @callback observations(term()) :: [{atom(), [String.t()]}]
  @optional_callbacks observations: 1

  def snapshot({module, context}) do
    module.snapshot(context)
  catch
    _, _ -> %{}
  end

  def execute({module, context}, operation, params) do
    module.execute(operation, params, context)
  catch
    _, _ -> {:error, :failed}
  end

  def login_url({module, context}) do
    module.login_url(context)
  catch
    _, _ -> nil
  end
end

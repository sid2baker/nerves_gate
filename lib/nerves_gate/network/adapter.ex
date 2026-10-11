defmodule NervesGate.Network.Adapter do
  @moduledoc """
  Infrastructure boundary. Implementations may configure only LAN interfaces;
  USB provisioning must remain independent. Host implementations never touch
  workstation interfaces. Calls run outside Jido command evaluation.
  """
  @callback apply_config(map(), term()) :: :ok | {:error, term()}
  @callback snapshot(term()) :: map() | nil
  @callback observations(term()) :: [{atom(), [String.t()]}]
  @optional_callbacks observations: 1

  def apply_config({module, context}, network) do
    module.apply_config(network, context)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def snapshot({module, context}) do
    {:ok, module.snapshot(context)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end

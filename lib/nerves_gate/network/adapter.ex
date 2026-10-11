defmodule NervesGate.Network.Adapter do
  @moduledoc """
  Infrastructure boundary. Implementations may configure only LAN interfaces;
  USB provisioning must remain independent. Host implementations never touch
  workstation interfaces. Calls run outside Jido command evaluation.
  """
  @callback load(term()) :: {:ok, map()} | {:error, term()}
  @callback save(map(), term()) :: :ok | {:error, term()}
  @callback apply_config(map(), term()) :: :ok | {:error, term()}
  @callback restore(map(), term()) :: :ok | {:error, term()}
  @callback snapshot(term()) :: map() | nil
  @callback observations(term()) :: [{atom(), [String.t()]}]
  @optional_callbacks observations: 1

  def load({module, context}), do: module.load(context)
  def save({module, context}, network), do: module.save(network, context)

  def apply_config({module, context}, network), do: module.apply_config(network, context)

  def restore({module, context}, network), do: module.restore(network, context)

  def snapshot({module, context}), do: module.snapshot(context)
end

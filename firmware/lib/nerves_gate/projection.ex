defmodule NervesGate.Projection do
  @moduledoc """
  The UI read model. Inputs are sanitized domain snapshots, including device
  metadata. Replacing one input recomputes the entire view with no effects.
  The device and its LiveViews use this same reducer; form drafts live elsewhere.
  """
  alias NervesGate.Status

  defstruct [:inputs, :status]

  def new(inputs), do: %__MODULE__{inputs: inputs, status: derive(inputs)}

  def apply(%__MODULE__{inputs: inputs}, {:replace, domain, value})
      when domain in [:network, :remote, :equipment, :indicators, :buses, :ssh, :system, :storage] do
    new(Map.replace!(inputs, domain, value))
  end

  def disconnected, do: %__MODULE__{inputs: nil, status: Status.disconnected()}

  defp derive(inputs) do
    Status.build(
      inputs.network,
      inputs.remote,
      inputs.equipment,
      inputs.indicators,
      inputs.buses,
      inputs.ssh,
      inputs.system,
      inputs.storage
    )
  end
end

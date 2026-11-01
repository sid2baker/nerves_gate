defmodule IotrouterExpansion.Outputs do
  @moduledoc """
  `NervesGateSDK.Output` callbacks for digital output channels. Card output states
  are repeatable, so an unconfirmed or failed write is applied again after a
  second. A released Desire holds the last state: nothing is written.
  """
  @behaviour NervesGateSDK.Output
  alias IotrouterExpansion.Bus

  @retry_ms 1_000

  @impl true
  def apply(_id, nil, channels), do: {:applied, channels}

  def apply(id, value, channels) do
    {address, channel} = Map.fetch!(channels, id)

    outcome =
      try do
        case Bus.write(address, channel, value) do
          :ok -> :applied
          {:error, :not_confirmed} -> :unknown
          {:error, reason} -> {:failed, reason}
        end
      catch
        :exit, _ -> :unknown
      end

    if outcome != :applied, do: NervesGateSDK.Output.reapply_after(id, @retry_ms)
    {outcome, channels}
  end
end

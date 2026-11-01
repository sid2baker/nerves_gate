defmodule IotrouterExpansion.Card do
  @moduledoc """
  Platform endpoints for one discovered card. IDs include the chain address and
  the card type, so a different card at the same position never inherits another
  card's endpoints: `card<address>_<type>.di<n>`, `.do<n>` and `.do<n>_state`.

  Only pure digital cards are supported: inputs only or outputs only. Their slot
  holds one byte per channel; output cards echo their current output state, which
  is declared as readback evidence. Mixed and analog layouts are unknown.
  """
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition}

  # Type codes observed on the stock agent's bus; other names lack known codes.
  @names %{1 => "d1600", 2 => "d0016n"}
  @expected_interval_ms 3_000

  def name(%{type: type}), do: Map.get(@names, type, "type#{type}")
  def id(card), do: "card#{card.address}_#{name(card)}"

  def supported?(%{type: 1, ai: 0, ao: 0, di: 16, do: 0}), do: true
  def supported?(%{type: 2, ai: 0, ao: 0, di: 0, do: 16}), do: true
  def supported?(_), do: false

  def inputs(card) do
    for local <- input_ids(card),
        do: %InputDefinition{
          id: local,
          type: :boolean,
          expected_interval_ms: @expected_interval_ms
        }
  end

  def outputs(card) do
    for n <- channels(card.do),
        do: %OutputDefinition{
          id: "#{id(card)}.do#{n}",
          type: :boolean,
          on_release: :hold,
          evidence: [
            %Evidence{input: "iotrouter_expansion.#{id(card)}.do#{n}_state", role: :readback}
          ]
        }
  end

  @doc "Local output ID to `{address, channel}` for every output of `cards`."
  def output_channels(cards) do
    for card <- cards,
        n <- channels(card.do),
        into: %{},
        do: {"#{id(card)}.do#{n}", {card.address, n}}
  end

  @doc "Readings of one slot, keyed by local input ID."
  def readings(card, slot) do
    count = max(card.di, card.do)
    Enum.zip(input_ids(card), IotrouterExpansion.Protocol.channels(slot, count)) |> Map.new()
  end

  defp input_ids(%{di: di, do: 0} = card), do: for(n <- channels(di), do: "#{id(card)}.di#{n}")
  defp input_ids(card), do: for(n <- channels(card.do), do: "#{id(card)}.do#{n}_state")

  defp channels(0), do: []
  defp channels(count), do: 0..(count - 1)
end

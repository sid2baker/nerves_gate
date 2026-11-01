defmodule IotrouterExpansion.CardTest do
  use ExUnit.Case, async: true
  alias IotrouterExpansion.Card

  defp di, do: %{address: 1, type: 1, version: 3, di: 16, do: 0, ai: 0, ao: 0}
  defp outputs, do: %{address: 2, type: 2, version: 1, di: 0, do: 16, ai: 0, ao: 0}

  test "only captured digital layouts are accepted, not guessed analog/mixed/unknown cards" do
    assert Card.supported?(di())
    assert Card.supported?(outputs())

    for card <- [%{di() | type: 99}, %{di() | ai: 8}, %{di() | do: 16}, %{di() | di: 32}],
        do: refute(Card.supported?(card))
  end

  test "stable local IDs, boolean readings and output echo evidence" do
    assert Card.id(di()) == "card1_d1600"
    assert length(Card.inputs(di())) == 16
    assert Card.outputs(di()) == []
    assert length(Card.inputs(outputs())) == 16

    assert [%{id: "card2_d0016n.do0", on_release: :hold, evidence: [evidence]} | _] =
             Card.outputs(outputs())

    assert evidence.input == "iotrouter_expansion.card2_d0016n.do0_state"
    assert evidence.role == :readback
    assert Card.output_channels([di(), outputs()])["card2_d0016n.do15"] == {2, 15}
    readings = Card.readings(di(), <<1, 0, 1, 0::size(29)-unit(8)>>)
    assert readings["card1_d1600.di0"] == true
    assert readings["card1_d1600.di1"] == false
  end
end

defmodule NervesGate.IO.OutputStatusTest do
  use ExUnit.Case, async: true
  alias NervesGate.IO.OutputStatus
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition, Reading}

  @pump %OutputDefinition{
    id: "pump",
    type: :boolean,
    evidence: [
      %Evidence{input: "p.coil", role: :readback},
      %Evidence{
        input: "p.current",
        role: :physical,
        settle_ms: 5_000,
        expect: %{true => {:above, 1.0}, false => {:below, 0.2}}
      }
    ]
  }

  defp desire(value \\ true), do: %{value: value, epoch: 7, changed_at_ms: 1_000}
  defp applied(outcome, value \\ true), do: %{epoch: 7, value: value, outcome: outcome}

  defp input(type, value, at, interval \\ nil) do
    %{
      available?: true,
      stale?: false,
      definition: %InputDefinition{id: "x", type: type, expected_interval_ms: interval},
      reading: at && %Reading{input_id: "x", value: value, quality: :good, received_at_ms: at}
    }
  end

  defp status(inputs, applied, now, definition \\ @pump, desire \\ desire()),
    do: OutputStatus.derive(definition, desire, applied, inputs, now)

  test "no Desire is unknown regardless of evidence" do
    assert %{state: :unknown, reason: "No Desire"} =
             OutputStatus.derive(
               @pump,
               nil,
               nil,
               %{"p.coil" => input(:boolean, true, 2_000)},
               9_000
             )
  end

  test "physical evidence outranks readback in both directions" do
    coil = input(:boolean, true, 1_500)

    assert %{state: :mismatch, reason: "Physical evidence p.current disagrees"} =
             status(
               %{"p.coil" => coil, "p.current" => input(:float, 0.0, 7_000)},
               applied(:applied),
               8_000
             )

    assert %{state: :confirmed, reason: "Physical evidence agrees"} =
             status(
               %{
                 "p.coil" => input(:boolean, false, 1_500),
                 "p.current" => input(:float, 2.1, 7_000)
               },
               applied(:unknown),
               8_000
             )

    # Readback agrees but the stronger physical evidence is still settling.
    assert %{state: :pending, evidence: [%{state: :confirmed}, %{state: :pending}]} =
             status(
               %{"p.coil" => coil, "p.current" => input(:float, 2.1, 1_200)},
               applied(:applied),
               3_000
             )
  end

  test "stale or missing stronger evidence falls back to readback" do
    stale = %{input(:float, 2.1, 7_000) | stale?: true}

    assert %{state: :confirmed, reason: "Readback evidence agrees"} =
             status(%{"p.coil" => input(:boolean, true, 1_500), "p.current" => stale}, nil, 8_000)

    assert %{state: :confirmed} = status(%{"p.coil" => input(:boolean, true, 1_500)}, nil, 20_000)
  end

  test "readings at or before the change never confirm it" do
    assert %{evidence: [%{state: :pending}, _]} =
             status(%{"p.coil" => input(:boolean, true, 1_000)}, nil, 1_500)

    assert %{evidence: [%{state: :stale}, _]} =
             status(%{"p.coil" => input(:boolean, true, 1_000)}, nil, 5_000)
  end

  test "Apply outcomes without usable evidence follow the Status table" do
    plain = %OutputDefinition{id: "relay", type: :boolean}
    declared = %{@pump | evidence: [hd(@pump.evidence)]}

    assert %{state: :unknown, reason: "Applied; no evidence declared", applied: :applied} =
             status(%{}, applied(:applied), 1_500, plain)

    assert %{state: :pending, reason: "Waiting for the plugin's Apply outcome"} =
             status(%{}, nil, 1_500, plain)

    assert %{state: :mismatch, applied: :failed} =
             status(%{}, applied({:failed, :timeout}), 1_500, plain)

    # Settling evidence keeps an applied or uncertain outcome pending, then unknown.
    for outcome <- [:applied, :unknown] do
      coil = %{"p.coil" => input(:boolean, nil, nil)}
      assert %{state: :pending} = status(coil, applied(outcome), 1_500, declared)
      assert %{state: :unknown} = status(coil, applied(outcome), 5_000, declared)
    end

    # A failed Apply is a mismatch even while evidence is still settling.
    assert %{state: :mismatch} =
             status(
               %{"p.coil" => input(:boolean, nil, nil)},
               applied({:failed, :busy}),
               1_500,
               declared
             )
  end

  test "every stronger evidence role wins regardless of declaration order or Apply outcome" do
    roles = [:physical, :consequence, :estimate, :readback]

    for {stronger, index} <- Enum.with_index(roles),
        weaker <- Enum.drop(roles, index + 1),
        value <- [true, false],
        outcome <- [:applied, :unknown, {:failed, :busy}],
        reverse? <- [false, true] do
      evidence = [
        %Evidence{input: "p.stronger", role: stronger},
        %Evidence{input: "p.weaker", role: weaker}
      ]

      definition = %{@pump | evidence: if(reverse?, do: Enum.reverse(evidence), else: evidence)}
      expected = if value, do: :confirmed, else: :mismatch
      label = stronger |> Atom.to_string() |> String.capitalize()

      reason =
        if value, do: "#{label} evidence agrees", else: "#{label} evidence p.stronger disagrees"

      assert %{state: ^expected, reason: ^reason} =
               status(
                 %{
                   "p.stronger" => input(:boolean, value, 2_000),
                   "p.weaker" => input(:boolean, not value, 2_000)
                 },
                 applied(outcome),
                 3_000,
                 definition
               )
    end
  end

  test "within a role contradiction wins over settling, which wins over agreement" do
    definition = %{
      @pump
      | evidence: [
          %Evidence{input: "p.a", role: :physical},
          %Evidence{input: "p.b", role: :physical}
        ]
    }

    for evidence <- [definition.evidence, Enum.reverse(definition.evidence)] do
      definition = %{definition | evidence: evidence}
      pending = input(:boolean, nil, nil, 5_000)

      assert %{state: :mismatch, reason: "Physical evidence p.a disagrees"} =
               status(
                 %{"p.a" => input(:boolean, false, 2_000), "p.b" => pending},
                 nil,
                 3_000,
                 definition
               )

      assert %{state: :pending, reason: "Waiting for evidence"} =
               status(
                 %{"p.a" => input(:boolean, true, 2_000), "p.b" => pending},
                 nil,
                 3_000,
                 definition
               )

      assert %{state: :confirmed} =
               status(
                 %{"p.a" => input(:boolean, true, 2_000), "p.b" => input(:boolean, true, 2_000)},
                 nil,
                 3_000,
                 definition
               )
    end
  end

  test "unavailable or unusable stronger evidence cannot override fresh readback" do
    good = input(:float, 0.0, 7_000)

    for physical <- [
          %{good | available?: false},
          %{good | stale?: true},
          put_in(good.reading.quality, :invalid),
          put_in(good.reading.quality, :unknown)
        ] do
      assert %{state: :confirmed, reason: "Readback evidence agrees"} =
               status(
                 %{"p.coil" => input(:boolean, true, 7_000), "p.current" => physical},
                 nil,
                 8_000
               )
    end
  end

  test "outcomes for another epoch or value are ignored" do
    plain = %OutputDefinition{id: "relay", type: :boolean}

    assert %{applied: nil, state: :pending} =
             status(%{}, %{applied(:applied) | epoch: 6}, 1_500, plain)

    assert %{applied: nil} = status(%{}, applied(:applied, false), 1_500, plain)
  end

  test "tolerance and incompatible evidence" do
    valve = %OutputDefinition{
      id: "valve",
      type: :float,
      evidence: [%Evidence{input: "v.position", role: :readback, expect: {:tolerance, 2.0}}]
    }

    want = desire(40.0)

    assert %{state: :confirmed} =
             status(%{"v.position" => input(:float, 41.5, 2_000)}, nil, 3_000, valve, want)

    assert %{state: :mismatch} =
             status(%{"v.position" => input(:float, 43.0, 2_000)}, nil, 3_000, valve, want)

    assert %{evidence: [%{state: :unknown}]} =
             status(%{"v.position" => input(:string, "40", 2_000)}, nil, 3_000, valve, want)
  end
end

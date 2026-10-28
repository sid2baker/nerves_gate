defmodule WorkbenchWeb.PageFixtures do
  def assigns(extra \\ []),
    do:
      Keyword.merge(
        [
          bench: bench(),
          plugins: [],
          gateways: [],
          targets: [],
          images: [],
          job: job(),
          error: nil
        ],
        extra
      )

  def job,
    do: %{
      status: :idle,
      kind: nil,
      subject: nil,
      output: nil,
      result: nil,
      review: nil,
      recovery: nil
    }

  def gateway(extra \\ %{}) do
    Map.merge(
      %{
        node: :"nerves_gate@100.64.0.9",
        address: "nerves-gate.example.ts.net",
        source: :network,
        sim_id: nil,
        connected: true,
        last_seen: ~U[2026-10-27 12:00:00Z],
        error: nil,
        identity: %{
          node: :"nerves_gate@100.64.0.9",
          target: "ec100",
          firmware: "0.3.0",
          source_revision: String.duplicate("a", 40),
          serial: "board-42",
          elixir: "1.20.4",
          otp: "29"
        }
      },
      extra
    )
  end

  def bench do
    %{
      blocked: false,
      devices: %{},
      runs: [],
      events: [],
      scenarios: [],
      lifecycle: %{
        status: :stopped,
        phase: "Stopped",
        prepared: false,
        reset_required: false,
        devices: [
          %{
            id: :gateway_a,
            address: "10.203.42.2",
            node: :"nerves_gate@10.203.42.2",
            internet: :lan1
          }
        ]
      }
    }
  end
end

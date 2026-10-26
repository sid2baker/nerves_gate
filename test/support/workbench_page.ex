defmodule WorkbenchWeb.PageFixtures do
  def assigns(extra \\ []),
    do:
      Keyword.merge(
        [
          bench: bench(),
          applications: [],
          images: [],
          discovery: %{status: :idle, devices: [], error: nil},
          operation: operation(),
          error: nil
        ],
        extra
      )

  def operation, do: %{status: :idle, kind: nil, output: nil, result: nil, review: nil}

  def bench do
    %{
      blocked: false,
      devices: %{},
      runs: [],
      events: [],
      lifecycle: %{
        status: :stopped,
        phase: "Stopped",
        prepared: false,
        reset_required: false,
        devices: [
          %{id: :gateway_a, address: "127.0.0.2", node: :gateway_a@localhost, internet: :lan1}
        ]
      }
    }
  end
end

defmodule NervesGate.Equipment.Host do
  @moduledoc "In-memory equipment simulator. Never opens sockets or touches workstation files."
  use Agent
  @behaviour NervesGate.Equipment.Adapter

  def start_link(opts \\ []),
    do:
      Agent.start_link(fn -> %{entries: [], labels: %{}} end,
        name: Keyword.get(opts, :name, __MODULE__)
      )

  def simulate(entries, server \\ __MODULE__),
    do: Agent.update(server, &%{&1 | entries: entries})

  @impl true
  def neighbors(_, server), do: Agent.get(server, &{:ok, &1.entries})
  @impl true
  def scan(scope, server), do: neighbors(scope, server)
  @impl true
  def load_labels(server), do: Agent.get(server, &{:ok, &1.labels})
  @impl true
  def save_labels(labels, server), do: Agent.update(server, &%{&1 | labels: labels})
end

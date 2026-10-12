defmodule NervesGate.TestEquipmentAdapter do
  @moduledoc false
  @behaviour NervesGate.Equipment.Adapter
  alias NervesGate.Equipment.Host

  @impl true
  def neighbors(scope, %{observe: true} = ctx), do: wait(:observing, scope, ctx)
  def neighbors(scope, ctx), do: Host.neighbors(scope, ctx.host)

  @impl true
  def load_labels(ctx), do: Host.load_labels(ctx.host)

  @impl true
  def save_labels(labels, ctx), do: Host.save_labels(labels, ctx.host)

  @impl true
  def scan(scope, ctx), do: wait(:scanning, scope, ctx)

  defp wait(kind, scope, ctx) do
    send(ctx.owner, {kind, self(), scope})

    receive do
      :continue -> Host.neighbors(scope, ctx.host)
      {:return, result} -> result
    end
  end
end

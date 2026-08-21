defmodule NervesGateWeb.Presence do
  @moduledoc "Tracks unique tailnet visitors across the connected gateway cluster."

  use Phoenix.Presence,
    otp_app: :nerves_gate,
    pubsub_server: NervesGate.PubSub

  @topic "tailnet_visitors"

  @spec track_visitor(pid(), map()) :: {:ok, reference()} | {:error, term()}
  def track_visitor(pid, actor) do
    key = actor.ip || actor.name
    track(pid, @topic, key, %{name: actor.name, joined_at: System.system_time(:second)})
  end

  @spec count() :: non_neg_integer()
  def count, do: @topic |> list() |> map_size()

  @spec topic() :: String.t()
  def topic, do: @topic
end

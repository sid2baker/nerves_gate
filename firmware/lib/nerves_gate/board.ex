defmodule NervesGate.Board do
  @moduledoc """
  Hardware wiring and adapters declared by the firmware target's `:board` config.
  The BSP supplies Linux devices; domains own their behaviour and persistence.
  Host builds have no board hardware.
  """

  def get(key), do: Application.get_env(:nerves_gate, :board, %{}) |> Map.get(key)

  def fetch!(key), do: Application.fetch_env!(:nerves_gate, :board) |> Map.fetch!(key)

  @doc "Interface names of the declared `:ethernet` resources, in board order."
  def ethernet, do: for(%{kind: :ethernet, id: id} <- get(:ports) || [], do: id)

  @doc "The board label of a declared resource, or nil."
  def label(id), do: Enum.find_value(get(:ports) || [], &(&1.id == id && &1.label))
end

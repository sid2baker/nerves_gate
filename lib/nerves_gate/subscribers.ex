defmodule NervesGate.Subscribers do
  @moduledoc false

  @type t :: %{
          optional(pid()) => %{required(:reference) => reference(), optional(atom()) => term()}
        }

  @spec add(t(), pid(), map()) :: t()
  def add(subscribers, subscriber, metadata \\ %{}) do
    Map.put_new_lazy(subscribers, subscriber, fn ->
      Map.put(metadata, :reference, Process.monitor(subscriber))
    end)
  end

  @spec remove(t(), pid()) :: t()
  def remove(subscribers, subscriber) do
    case Map.pop(subscribers, subscriber) do
      {nil, subscribers} ->
        subscribers

      {%{reference: reference}, subscribers} ->
        Process.demonitor(reference, [:flush])
        subscribers
    end
  end

  @spec down(t(), pid(), reference()) :: t()
  def down(subscribers, subscriber, reference) do
    case Map.get(subscribers, subscriber) do
      %{reference: ^reference} -> Map.delete(subscribers, subscriber)
      _stale -> subscribers
    end
  end
end

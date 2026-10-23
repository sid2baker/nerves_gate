defmodule NervesGate.Network.CellularPIN do
  @moduledoc """
  SIM-bound PIN for automatic unlock, kept in the persistent `NervesGate.Settings`
  table. Never put it in domain state or projections.

  Persistence is not encryption: anyone who can read the data partition can read
  the PIN. Consuming the PIN blocks further automatic attempts before returning
  it; only a known-successful PIN operation may save and arm it again. Observing
  READY alone must never re-arm it.
  """

  @table NervesGate.Settings
  @key ["cellular", "pin"]
  @error {:error, :cellular_pin_storage}

  @doc false
  def save(pin, identity, table \\ @table) do
    if valid_pin?(pin) and valid_identity?(identity),
      do: put(table, %{pin: pin, sim_fingerprint: fingerprint(identity), armed: true}),
      else: @error
  end

  @doc false
  def block(table \\ @table) do
    case PropertyTable.get(table, @key) do
      nil -> :ok
      record -> put(table, %{record | armed: false})
    end
  end

  @doc false
  def consume(identity, table \\ @table) do
    with record when record != nil <- PropertyTable.get(table, @key),
         :ready <- state(record, identity),
         :ok <- put(table, %{record | armed: false}) do
      {:ok, record.pin}
    else
      nil -> {:error, :cellular_pin_not_saved}
      state when is_atom(state) -> {:error, :cellular_auto_unlock_blocked}
      error -> error
    end
  end

  @doc false
  def forget(table \\ @table) do
    PropertyTable.delete(table, @key)
    flush(table)
  end

  @doc false
  def metadata(identity \\ nil, table \\ @table) do
    case PropertyTable.get(table, @key) do
      nil -> %{pin_saved: false, auto_unlock: :off}
      record -> %{pin_saved: true, auto_unlock: state(record, identity)}
    end
  end

  defp state(%{armed: false}, _), do: :blocked

  defp state(record, identity) do
    cond do
      not valid_identity?(identity) -> :identity_unknown
      record.sim_fingerprint != fingerprint(identity) -> :different_sim
      true -> :ready
    end
  end

  defp put(table, record) do
    PropertyTable.put(table, @key, record)
    flush(table)
  end

  defp flush(table) do
    case PropertyTable.flush_to_disk(table) do
      :ok -> :ok
      _ -> @error
    end
  end

  defp valid_pin?(pin), do: is_binary(pin) and Regex.match?(~r/\A[0-9]{4,8}\z/, pin)

  defp valid_identity?(identity),
    do: is_binary(identity) and Regex.match?(~r/\A[0-9]{18,22}\z/, identity)

  defp fingerprint(identity), do: :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
end

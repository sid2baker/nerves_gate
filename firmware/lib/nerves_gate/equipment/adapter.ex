defmodule NervesGate.Equipment.Adapter do
  @moduledoc "Equipment observations, explicit ARP probes and label persistence."
  @callback neighbors(map(), term()) :: {:ok, [map()]} | {:error, term()}
  @callback scan(map(), term()) :: {:ok, [map()]} | {:error, term()}
  @callback load_labels(term()) :: {:ok, map()} | {:error, term()}
  @callback save_labels(map(), term()) :: :ok | {:error, term()}
end

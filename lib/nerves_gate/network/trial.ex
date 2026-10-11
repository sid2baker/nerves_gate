defmodule NervesGate.Network.Trial do
  @moduledoc """
  Durable trial data. The wall-clock expiry is presentation metadata only.
  Every pending trial rolls back after restart, regardless of clock accuracy.
  A live runtime uses an independent monotonic deadline.
  """
  alias NervesGate.Config

  @keys ~w(version id phase previous requested auto_save expires_at)

  def new(previous, network, auto_save, timeout) do
    %{
      "version" => 1,
      "id" => Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      "phase" => "pending",
      "previous" => previous,
      "requested" => %{previous | "network" => network, "setup_completed" => true},
      "auto_save" => auto_save,
      "expires_at" => System.system_time(:millisecond) + timeout
    }
  end

  def validate(record) when is_map(record) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(@keys),
         1 <- record["version"],
         id when is_binary(id) and byte_size(id) == 32 <- record["id"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
         phase when phase in ["pending", "confirmed"] <- record["phase"],
         true <- is_boolean(record["auto_save"]),
         true <- is_integer(record["expires_at"]),
         {:ok, previous} <- Config.validate(record["previous"]),
         {:ok, requested} <- Config.validate(record["requested"]),
         true <- requested["setup_completed"] do
      {:ok, %{record | "previous" => previous, "requested" => requested}}
    else
      _ -> {:error, :invalid_trial_record}
    end
  end

  def validate(_), do: {:error, :invalid_trial_record}

  def recovery_config(%{"phase" => "pending", "previous" => previous}), do: previous
  def recovery_config(%{"phase" => "confirmed", "requested" => requested}), do: requested

  def public(record) do
    %{
      id: record["id"],
      network: record["requested"]["network"],
      auto_save: record["auto_save"],
      expires_at: record["expires_at"]
    }
  end
end

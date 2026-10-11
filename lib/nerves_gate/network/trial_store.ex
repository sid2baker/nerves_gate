defmodule NervesGate.Network.TrialStore do
  @moduledoc """
  Durable decision journal, adjacent to the existing configuration file.

  Begin: sync previous config, then sync pending journal, then permit hardware.
  Confirm: sync requested config, then sync the confirmed journal (commit point).
  A crash before that decision restores previous settings, even when the config
  file already contains requested settings. After it, recovery finishes the new
  commit. Cleanup is never the commit point.

  An uncertain confirmed-marker write is NOT a rollback instruction. It returns
  `:outcome_unknown`; recovery reads the journal and finishes its recorded decision.
  No acknowledgement claims success before both durable writes have succeeded.
  """
  alias NervesGate.{AtomicFile, Config}
  alias NervesGate.Network.Trial

  def path(config_path), do: config_path <> ".trial"

  def load(config_path, storage \\ AtomicFile) do
    case storage.read(path(config_path)) do
      {:ok, contents} ->
        with {:ok, record} <- Jason.decode(contents), do: Trial.validate(record)

      {:error, :enoent} ->
        {:ok, nil}

      error ->
        error
    end
  end

  def prepare(record, config_path, storage \\ AtomicFile) do
    with {:ok, nil} <- load(config_path, storage),
         {:ok, record} <- Trial.validate(record),
         "pending" <- record["phase"],
         :ok <- Config.save(record["previous"], config_path, storage) do
      write(record, config_path, storage)
    else
      {:ok, _record} -> {:error, :recovery_in_progress}
      "confirmed" -> {:error, :invalid_trial_record}
      error -> error
    end
  end

  def confirm(%{"phase" => "pending"} = record, config_path, storage \\ AtomicFile) do
    case Config.save(record["requested"], config_path, storage) do
      :ok -> confirm_decision(record, config_path, storage)
      {:error, reason} -> {:error, {:save, reason}, :rollback}
    end
  end

  def clear(config_path, storage \\ AtomicFile), do: storage.remove(path(config_path))

  defp confirm_decision(record, config_path, storage) do
    confirmed = %{record | "phase" => "confirmed"}

    case write(confirmed, config_path, storage) do
      :ok -> {:ok, confirmed}
      {:error, {:uncertain, _}} -> {:error, :outcome_unknown, :reconcile}
      {:error, reason} -> {:error, {:save, reason}, :rollback}
    end
  end

  defp write(record, config_path, storage) do
    storage.write(path(config_path), Jason.encode!(record) <> "\n")
  end
end

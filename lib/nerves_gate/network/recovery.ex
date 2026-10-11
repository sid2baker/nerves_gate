defmodule NervesGate.Network.Recovery do
  @moduledoc """
  Idempotent startup/interruption recovery. Hardware and the config file follow
  the durable journal's decision, never a Jido checkpoint or a wall-clock timer.
  New proposals remain blocked until recovery (including cleanup) succeeds.
  """
  alias NervesGate.{AtomicFile, Config}
  alias NervesGate.Network.{Adapter, Trial, TrialStore}

  def restore(config_path, adapter, storage \\ AtomicFile) do
    case TrialStore.load(config_path, storage) do
      {:ok, nil} -> restore_saved(config_path, adapter, storage)
      {:ok, record} -> finish(record, config_path, adapter, storage)
      {:error, reason} -> {:error, {:load, reason}}
    end
  end

  def finish(record, config_path, adapter, storage \\ AtomicFile) do
    config = Trial.recovery_config(record)

    # Restore hardware even if persistence is temporarily unavailable. Keep the
    # journal until BOTH have succeeded, so a restart repeats the same decision.
    saved = Config.save(config, config_path, storage)
    applied = Adapter.apply_config(adapter, config["network"])

    with :ok <- saved,
         :ok <- applied,
         :ok <- TrialStore.clear(config_path, storage) do
      {:ok, config}
    else
      {:error, reason} -> {:error, {:restore, reason}}
    end
  end

  defp restore_saved(path, adapter, storage) do
    with {:ok, config} <- Config.load(path, storage),
         :ok <- Adapter.apply_config(adapter, config["network"]) do
      {:ok, config}
    else
      {:error, reason} -> {:error, {:restore, reason}}
    end
  end
end

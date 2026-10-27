defmodule Workbench.DeviceInspection do
  @moduledoc "Read-only inspection from the attached Workbench runtime, using its verified device directory."

  @timeout 5_000
  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @doc "List this Workbench's gateways, connected or last seen. Opens no connections."
  def devices, do: Workbench.Gateways.list()

  @doc "Read build/runtime identity."
  def identity(target), do: call(target, NervesGate.System, :info)

  @doc "Read supported administrative domain state."
  def status(target), do: call(target, NervesGate, :status)

  @doc "Read plugin selections, activation state and errors."
  def plugins(target), do: call(target, NervesGate.Plugins, :list)

  @doc "Read bus inventory and assignments; never query caller-owned plugin resources."
  def hardware(target), do: call(target, NervesGate.Hardware, :status)

  @doc "Read the latest 1–100 entries, filtered by minimum level (default warning). Output is capped at 16 KB."
  def logs(target, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    level = Keyword.get(opts, :level, :warning)

    if limit in 1..100 and level in @levels do
      with {:ok, entries} <- call(target, RingLogger.Server, :tail, [limit]) do
        {:ok, Workbench.DeviceInspection.Logs.format(entries, level)}
      end
    else
      {:error, :invalid_log_options}
    end
  end

  defp call(target, module, function, args \\ []) do
    with {:ok, %{node: node}} <- Workbench.Gateways.fetch(target) do
      case :erpc.call(node, module, function, args, @timeout) do
        {:ok, _} = result -> result
        {:error, _} = result -> result
        result -> {:ok, result}
      end
    end
  catch
    :error, {:erpc, reason} -> {:error, reason}
    kind, _ -> {:error, {:rpc_failed, kind}}
  end
end

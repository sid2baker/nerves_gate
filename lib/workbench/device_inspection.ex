defmodule Workbench.DeviceInspection do
  @moduledoc "Read-only development-device inspection over distribution, using the fixed dev cookie."

  @timeout 5_000
  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @doc "Connect to a dev node. Does not start any device services."
  def connect(target) do
    with {:ok, node} <- node_name(target) do
      if node == Node.self() do
        {:ok, node}
      else
        with :ok <- distribution() do
          Node.set_cookie(node, :mycookie)
          task = Task.async(fn -> Node.connect(node) end)

          case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, true} -> {:ok, node}
            _ -> {:error, :connection_failed}
          end
        end
      end
    end
  end

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
    with {:ok, node} <- connect(target) do
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

  defp node_name(target) when is_atom(target), do: node_name(Atom.to_string(target))

  defp node_name(target) when is_binary(target) and byte_size(target) in 3..255 do
    if String.contains?(target, "@"),
      do: {:ok, String.to_atom(target)},
      else: {:error, :invalid_node}
  end

  defp node_name(_), do: {:error, :invalid_node}

  defp distribution do
    if Node.alive?() do
      :ok
    else
      {:ok, interfaces} = :inet.getifaddrs()

      addresses =
        for {_, attrs} <- interfaces, {:addr, {a, _, _, _} = ip} <- attrs, a != 127, do: ip

      ip = Enum.find(addresses, &(elem(&1, 0) == 100)) || List.first(addresses) || {127, 0, 0, 1}
      name = String.to_atom("gate_inspect_#{System.pid()}@#{:inet.ntoa(ip)}")

      case Node.start(name, :longnames) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> {:error, :distribution_unavailable}
      end
    end
  end
end

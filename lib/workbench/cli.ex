defmodule Workbench.CLI do
  @moduledoc """
  Mix task front ends. Session work is an ordinary function call on the attached
  Workbench node; nothing here talks HTTP.

      mix test.qemu [--only ID] [--device ID]   # run on the running session
      mix test.qemu --lifecycle start|stop|reset # reset erases every simulated disk
      mix test.qemu --ci [--only ID] [--config PATH]   # disposable bench
  """
  alias Workbench.Session

  def test_qemu(args) do
    {options, []} =
      OptionParser.parse!(args,
        strict: [
          ci: :boolean,
          only: :string,
          device: :string,
          lifecycle: :string,
          config: :string
        ]
      )

    cond do
      options[:ci] ->
        if options[:device] || options[:lifecycle],
          do: Mix.raise("--ci runs on the first device of a disposable bench")

        Workbench.Launcher.run(args)

      options[:config] ->
        Mix.raise("Use --config only with --ci; mix dev owns the running configuration")

      action = options[:lifecycle] ->
        unless action in ~w(start stop reset),
          do: Mix.raise("Expected --lifecycle start|stop|reset")

        monitor = watch()
        ok!(call(Scenarios.Runner, :lifecycle, [action]))

        await_lifecycle(
          if(action == "start", do: :ready, else: :stopped),
          deadline(900_000),
          nil,
          monitor
        )

      true ->
        monitor = watch()
        devices = call(Scenarios.Runner, :snapshot, []).lifecycle.devices
        device = options[:device] || (List.first(devices) || Mix.raise("No simulated devices")).id
        {:ok, id} = ok!(call(Scenarios.Runner, :run, [device, options[:only] || "all"]))
        IO.puts("Run ##{id} on #{device}")
        await_run(id, MapSet.new(), deadline(900_000), monitor)
    end
  end

  def plugin(command, args) do
    {options, paths} = OptionParser.parse!(args, strict: [device: :string, local_sdk: :boolean])

    path =
      case paths do
        [path] -> Path.expand(path)
        _ -> Mix.raise("Usage: mix plugin.#{command} PLUGIN_DIRECTORY [--device ID]")
      end

    case command do
      :new ->
        plugin = Workbench.Plugins.scaffold!(path, local_sdk: options[:local_sdk] || false)
        if Session.info(), do: call(Workbench.Plugins, :open, [plugin.path])
        IO.puts("Created #{plugin.path}")

      :test ->
        Workbench.Plugins.test!(path)

      :package ->
        IO.puts(Workbench.Plugins.package!(path))

      :install ->
        monitor = watch()
        devices = call(Scenarios.Runner, :snapshot, []).lifecycle.devices

        device =
          options[:device] ||
            case devices do
              [%{id: id}] -> id
              _ -> Mix.raise("Select --device")
            end

        package = Workbench.Plugins.package!(path, fn _ -> :ok end, :temporary)

        try do
          {:ok, id} = ok!(call(Scenarios.Runner, :install, [device, package]))
          await_run(id, MapSet.new(), deadline(900_000), monitor)
        after
          File.rm(package)
        end
    end
  end

  @doc false
  def print_rows(run, printed) do
    Enum.reduce(run.rows, printed, fn row, printed ->
      if row.status in [:passed, :failed, :skipped] and not MapSet.member?(printed, row.id) do
        IO.puts("#{row.status}: #{row.id} (#{row.milliseconds} ms) #{row.detail}")
        MapSet.put(printed, row.id)
      else
        printed
      end
    end)
  end

  defp await_run(id, printed, deadline, monitor, snapshot \\ nil) do
    snapshot = snapshot || call(Scenarios.Runner, :snapshot, [])

    case Enum.find(snapshot.runs, &(&1.id == id)) do
      %{status: :passed} = run ->
        print_rows(run, printed)
        :ok

      %{status: :running} = run ->
        printed = print_rows(run, printed)
        await_run(id, printed, deadline, monitor, next_snapshot(deadline, monitor))

      nil ->
        # Progress queued while packaging may predate this run.
        await_run(id, printed, deadline, monitor, next_snapshot(deadline, monitor))

      run ->
        print_rows(run, printed)
        Mix.raise("Run #{run.status}; inspect the device page")
    end
  end

  defp await_lifecycle(target, deadline, previous, monitor, snapshot \\ nil) do
    snapshot = snapshot || call(Scenarios.Runner, :snapshot, [])
    lifecycle = snapshot.lifecycle
    if lifecycle.phase != previous, do: IO.puts(lifecycle.phase)

    cond do
      lifecycle.status == target ->
        :ok

      lifecycle.status in [:failed, :unavailable] ->
        Mix.raise(lifecycle.phase)

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("Lifecycle outcome unknown; inspect the site")

      true ->
        await_lifecycle(
          target,
          deadline,
          lifecycle.phase,
          monitor,
          next_snapshot(deadline, monitor)
        )
    end
  end

  defp watch do
    {owner, _} = call(Scenarios.Runner, :watch, [self()])
    Process.monitor(owner)
  end

  defp next_snapshot(deadline, monitor) do
    receive do
      {:scenarios, snapshot} ->
        snapshot

      {:DOWN, ^monitor, :process, _, _} ->
        Mix.raise("Workbench stopped; outcome unknown. Do not replay")
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Mix.raise("Operation deadline reached; outcome unknown. Inspect before retrying")
    end
  end

  defp call(module, function, args) do
    case Session.call(module, function, args) do
      {:error, :not_running} ->
        Mix.raise("Start mix dev first.")

      {:error, reason} when not is_binary(reason) ->
        Mix.raise("Workbench unreachable: #{inspect(reason)}")

      result ->
        result
    end
  end

  defp ok!(:ok), do: :ok
  defp ok!({:ok, _} = ok), do: ok
  defp ok!({:error, message}), do: Mix.raise(message)

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

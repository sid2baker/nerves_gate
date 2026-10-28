defmodule Workbench.CLI do
  @moduledoc """
  Mix task front ends. Session work is an ordinary function call on the attached
  Workbench node; nothing here talks HTTP.

      mix test.qemu [--only ID] [--device ID]   # run on the running session
      mix test.qemu --lifecycle start|stop|reset # reset erases every simulated disk
      mix test.qemu --ci [--only ID] [--config PATH]   # disposable bench
      mix firmware.update GATEWAY [IMAGE] [--sha256 SHA] # reviewed physical update
  """

  @image "firmware/_build/ec100_dev/nerves/images/nerves_gate.fw"
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

  @doc """
  Print gateway state, review the image, confirm once (interactively or by exact
  `--sha256`), wait for the verified outcome and print the state again.
  """
  def firmware_update(args) do
    {options, positional} = OptionParser.parse!(args, strict: [sha256: :string])

    {name, image} =
      case positional do
        [name] -> {name, @image}
        [name, image] -> {name, image}
        _ -> Mix.raise("Usage: mix firmware.update GATEWAY [IMAGE] [--sha256 SHA]")
      end

    gateway =
      Enum.find(call(Workbench.Gateways, :list, []), &(name in [to_string(&1.node), &1.address])) ||
        Mix.raise("No connected gateway #{name}")

    print_state("Before", gateway.node)
    ok!(call(Workbench.Jobs, :review_firmware, [gateway.node, Path.expand(image)]))

    case await_job(deadline(300_000), nil) do
      %{status: :awaiting_confirmation, review: review} ->
        IO.puts("Review:\n" <> inspect(Map.delete(review, :token), pretty: true))

        confirmed? =
          if sha = options[:sha256],
            do: sha == review.sha256 || Mix.raise("Reviewed image is not #{sha}; nothing sent"),
            else: Mix.shell().yes?("Send this exact image to #{review.serial}?", default: :no)

        unless confirmed?, do: Mix.raise("Not confirmed; nothing sent")
        ok!(call(Workbench.Jobs, :confirm_firmware, [review.token, review.address]))

        case await_job(deadline(600_000), nil) do
          %{status: :succeeded, result: result} ->
            IO.puts(result)
            print_state("After", gateway.node)

          job ->
            Mix.raise("#{job.result} Do not retry; inspect the gateway.")
        end

      job ->
        Mix.raise(job.result)
    end
  end

  defp print_state(label, node) do
    state = call(Workbench.FirmwareUpdate, :state, [node])
    IO.puts("#{label}:\n" <> inspect(state, pretty: true, limit: :infinity))
  end

  defp await_job(deadline, output) do
    job = call(Workbench.Jobs, :snapshot, [])
    if job.output != output and job.output, do: IO.puts(job.output)

    cond do
      job.status != :running ->
        job

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("Outcome unknown; inspect the gateway. Do not retry")

      true ->
        Process.sleep(1_000)
        await_job(deadline, job.output)
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

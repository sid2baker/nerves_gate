defmodule Workbench.CLI.Scenario do
  @moduledoc "Explicit scenario selection; lifecycle is not a test option."
  alias Workbench.CLI

  def list([]) do
    for {kind, rows} <- [qemu: Scenarios.all(), physical: Scenarios.physical()],
        row <- rows,
        do:
          CLI.print(%{
            kind: kind,
            id: row.id,
            requires: row.requires,
            fresh_disk: row.fresh_disk,
            all_devices: row.all
          })
  end

  def list(_), do: Mix.raise("Usage: mix scenario.list")

  def run(args) do
    {options, selection} = OptionParser.parse!(args, strict: [device: :string])

    id =
      case selection do
        [id] -> id
        _ -> Mix.raise("Usage: mix scenario.run ID --device TARGET")
      end

    target = options[:device] || Mix.raise("Select --device TARGET explicitly")
    {:ok, gateway} = CLI.call(Workbench.Gateways, :fetch, [target])

    case gateway do
      %{source: :network} ->
        {:ok, job} = CLI.command(Workbench.Jobs, :check, [gateway.node, id])
        CLI.success!(CLI.await_job(job))

      %{source: :qemu, sim_id: device} ->
        {:ok, run} = CLI.command(Scenarios.Runner, :run, [device, id])
        result = CLI.await_runner(run)
        CLI.print_rows(result, MapSet.new())
        CLI.success!(result)
    end
  end

  def ci(args) do
    {options, selection} = OptionParser.parse!(args, strict: [device: :string, config: :string])

    case selection do
      [id] ->
        if Scenarios.select(id) == [], do: Mix.raise("Unknown QEMU scenario #{id}")

        device =
          options[:device] || Mix.raise("Select --device ID in the disposable configuration")

        Workbench.Launcher.ci(id, device, options[:config])

      _ ->
        Mix.raise("Usage: mix scenario.ci ID --device ID [--config PATH]")
    end
  end
end

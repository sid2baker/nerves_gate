defmodule Workbench.CLI.Gateway do
  @moduledoc "Read-only directory, gateway and bounded log observations."
  alias Workbench.CLI

  def list([]), do: CLI.print(CLI.call(Workbench.DeviceInspection, :devices))
  def list(_), do: Mix.raise("Usage: mix gateway.list")

  def inspect_gateway([target]) do
    for function <- [:identity, :status, :plugins, :hardware] do
      {:ok, result} = CLI.call(Workbench.DeviceInspection, function, [target])
      IO.puts("#{function}:")
      CLI.print(result)
    end
  end

  def inspect_gateway(_), do: Mix.raise("Usage: mix gateway.inspect TARGET")

  def logs(args) do
    {options, targets} = OptionParser.parse!(args, strict: [limit: :integer])

    case targets do
      [target] ->
        {:ok, logs} =
          CLI.call(Workbench.DeviceInspection, :logs, [target, [limit: options[:limit] || 50]])

        CLI.print(logs)

      _ ->
        Mix.raise("Usage: mix gateway.logs TARGET [--limit 1..100]")
    end
  end
end

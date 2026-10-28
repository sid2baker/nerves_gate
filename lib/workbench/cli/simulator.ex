defmodule Workbench.CLI.Simulator do
  @moduledoc "Explicit owned-QEMU lifecycle commands."
  alias Workbench.CLI

  def run(action, args) do
    {options, []} = OptionParser.parse!(args, strict: [confirm: :boolean])

    if action != "reset" and options[:confirm],
      do: Mix.raise("--confirm is only supported for reset")

    if action == "reset" and not options[:confirm] and
         not Mix.shell().yes?("Erase every owned simulated device disk and its saved settings?",
           default: :no
         ),
       do: Mix.raise("Reset not confirmed; no disks changed")

    {:ok, id} = CLI.command(Scenarios.Runner, :lifecycle, [action])
    CLI.success!(CLI.await_runner(id))
  end
end

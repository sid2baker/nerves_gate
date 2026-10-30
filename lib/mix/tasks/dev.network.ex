defmodule Mix.Tasks.Dev.Network do
  use Mix.Task
  @shortdoc "Explicitly prepare or remove this checkout's private QEMU bridge/TAPs"
  @moduledoc """
  With this checkout's Workbench stopped and sudo access authorized:

      mix dev.network setup --subnet <private-/24> [--config PATH]
      mix dev.network cleanup

  Setup recreates a complete recorded network after reboot only when all its
  bridge/TAP names are absent and the subnet, device set and owner are unchanged.
  Host routes are checked again. Surviving/conflicting interfaces or incomplete
  setup still require inspection and explicit cleanup. Nothing is repaired by
  ordinary Workbench startup.
  """
  @requirements ["app.config"]

  def run(["setup" | args]) do
    {options, []} = OptionParser.parse!(args, strict: [subnet: :string, config: :string])
    subnet = options[:subnet] || Mix.raise("Supply --subnet <private-/24>")
    {config, _} = Code.eval_file(options[:config] || Simulator.script("simulator"))
    Workbench.ManagementNetwork.setup!(subnet, Map.keys(config.devices))

    Mix.shell().info(
      "Management network prepared. Start mix dev normally; no devices were booted."
    )
  end

  def run(["cleanup"]) do
    Workbench.ManagementNetwork.cleanup!()
    Mix.shell().info("Recorded management network removed.")
  end

  def run(_),
    do:
      Mix.raise(
        "Usage: mix dev.network setup --subnet <private-/24> [--config PATH] | cleanup. Review host routes and authorize sudo first."
      )
end

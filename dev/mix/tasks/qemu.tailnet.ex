defmodule Mix.Tasks.Qemu.Tailnet do
  @moduledoc "Check GitHub OIDC access or clean up only this CI run's tailnet resources."
  use Mix.Task
  @shortdoc "Check OIDC access or clean up this run's QEMU tailnet resources"

  def run([action]) when action in ["check", "cleanup"] do
    Mix.Task.run("compile")

    case action do
      "check" ->
        NervesGate.TailnetAuth.client()
        NervesGate.TailnetAuth.prefix()
        Mix.shell().info("Tailscale OIDC token exchange succeeded; no devices were enrolled.")

      "cleanup" ->
        NervesGate.TailnetAuth.cleanup()
        Mix.shell().info("This run's recorded tailnet resources are removed.")
    end
  end
end

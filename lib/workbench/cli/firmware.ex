defmodule Workbench.CLI.Firmware do
  @moduledoc "Mix adapter for the reviewed firmware-update Jobs workflow."
  alias Workbench.CLI
  @image "firmware/_build/ec100_dev/nerves/images/nerves_gate.fw"

  def run(args) do
    {options, positional} = OptionParser.parse!(args, strict: [sha256: :string])

    {target, image} =
      case positional do
        [target] -> {target, @image}
        [target, image] -> {target, image}
        _ -> Mix.raise("Usage: mix firmware.update TARGET [IMAGE] [--sha256 SHA]")
      end

    {:ok, gateway} = CLI.call(Workbench.Gateways, :fetch, [target])
    CLI.print(CLI.call(Workbench.FirmwareUpdate, :state, [gateway.node]))
    {:ok, id} = CLI.command(Workbench.Jobs, :review_firmware, [gateway.node, Path.expand(image)])

    case CLI.await_job(id, 300_000) do
      %{status: :awaiting_confirmation, review: review} ->
        CLI.print(Map.delete(review, :token))

        confirmed =
          if sha = options[:sha256],
            do:
              sha == review.sha256 ||
                Mix.raise("SHA does not match the reviewed image; nothing sent"),
            else: Mix.shell().yes?("Send this exact image to #{review.serial}?", default: :no)

        unless confirmed, do: Mix.raise("Not confirmed; nothing sent")

        {:ok, update} =
          CLI.command(Workbench.Jobs, :confirm_firmware, [review.token, review.address])

        CLI.success!(CLI.await_job(update, 600_000))
        CLI.print(CLI.call(Workbench.FirmwareUpdate, :state, [gateway.node]))

      job ->
        CLI.success!(job)
    end
  end
end

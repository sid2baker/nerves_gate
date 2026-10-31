defmodule Workbench.CLI.Firmware do
  @moduledoc "Mix adapter for the reviewed firmware-update Jobs workflow."
  alias Workbench.CLI

  def run(args) do
    {options, positional} = OptionParser.parse!(args, strict: [sha256: :string])

    {target, image} =
      case positional do
        [target] -> {target, nil}
        [target, image] -> {target, image}
        _ -> Mix.raise("Usage: mix firmware.update TARGET [IMAGE] [--sha256 SHA]")
      end

    {:ok, gateway} = CLI.call(Workbench.Gateways, :fetch, [target])
    # Default: the dev build for the gateway's own board. Review rejects mismatches.
    image = image || default_image(gateway)
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

  defp default_image(%{identity: %{target: board}}),
    do: "firmware/_build/#{board}_dev/nerves/images/nerves_gate.fw"

  defp default_image(_),
    do: Mix.raise("Gateway identity is unavailable; pass the IMAGE path explicitly")
end

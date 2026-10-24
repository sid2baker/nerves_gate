defmodule Workbench.Console do
  # Print the SSH IEx command for an owned, manually reserved QEMU device.
  @moduledoc """
  `mix app.console [--device gateway_a]` prints a command to run in
  your terminal. Acquire idle Manual control on the device page first; release
  it only after closing the console. This never attaches to arbitrary VMs.

  The console grants full VM access, not just application access. Use
  `RingLogger.attach()` there to follow device/application logs. No credentials
  or private distribution cookies are printed by this task.
  """

  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args, strict: [device: :string])

    if rest != [] or invalid != [], do: Mix.raise("Usage: mix app.console [--device id]")

    {client, state} =
      Workbench.Session.connect("_build/workbench", 180_000) ||
        Mix.raise("Start mix dev and the device first.")

    device =
      case {options[:device], state["lifecycle"]["devices"]} do
        {id, _} when is_binary(id) -> id
        {nil, [%{"id" => id}]} -> id
        _ -> Mix.raise("Select --device from the running simulator.")
      end

    case Req.get!(client, url: "/api/console/#{URI.encode(device, &URI.char_unreserved?/1)}") do
      %{status: 200, body: %{"address" => address, "port" => port}} ->
        Mix.shell().info("Run in your terminal: ssh -t -p #{port} root@#{address}")

        Mix.shell().info(
          "Use USB recovery authentication. In IEx: RingLogger.attach(). Close SSH before releasing Manual control."
        )

      %{body: %{"error" => error}} ->
        Mix.raise(error)

      _ ->
        Mix.raise("Simulator console information is unavailable.")
    end
  end
end

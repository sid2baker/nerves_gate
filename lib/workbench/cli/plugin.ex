defmodule Workbench.CLI.Plugin do
  @moduledoc "Mix adapters for standalone plugin projects and admitted installations."
  alias Workbench.CLI

  def run(command, args) do
    {options, paths} = OptionParser.parse!(args, strict: [device: :string, local_sdk: :boolean])

    path =
      case paths do
        [path] ->
          Path.expand(path)

        _ ->
          Mix.raise(
            "Usage: mix plugin.#{command} PATH" <>
              if(command == :install, do: " --device TARGET", else: "")
          )
      end

    if command != :install and options[:device],
      do: Mix.raise("--device is only supported for install")

    if command != :new and options[:local_sdk],
      do: Mix.raise("--local-sdk is only supported for new")

    case command do
      :new ->
        plugin = Workbench.Plugins.scaffold!(path, local_sdk: options[:local_sdk] || false)
        IO.puts("Created #{plugin.path}")

      :test ->
        Workbench.Plugins.test!(path)

      :package ->
        IO.puts(Workbench.Plugins.package!(path))

      :install ->
        target = options[:device] || Mix.raise("Select --device TARGET from mix gateway.list")
        {:ok, id} = CLI.command(Workbench.Jobs, :install_plugin, [path, target])

        case CLI.await_job(id) do
          %{status: :awaiting_confirmation, review: review} ->
            CLI.print(Map.delete(review, :token))

            unless Mix.shell().yes?("Install this exact plugin on #{review.address}?",
                     default: :no
                   ),
                   do: Mix.raise("Not confirmed; nothing sent")

            {:ok, install} =
              CLI.command(Workbench.Jobs, :confirm_plugin, [review.token, review.address])

            CLI.success!(CLI.await_job(install))

          job ->
            CLI.success!(job)
        end
    end
  end
end

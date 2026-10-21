defmodule Dev do
  @moduledoc "The workstation developer platform. Starting it never starts devices."
  @root Path.expand("..", __DIR__)
  @external_resource Path.join(@root, "VERSION")
  @version @external_resource |> File.read!() |> String.trim()

  def root, do: @root
  def version, do: @version
  def script(name), do: Path.join(@root, "priv/dev/#{name}.exs")

  def configure do
    config =
      Enum.reduce(["config.exs", "runtime.exs"], [], fn name, config ->
        settings =
          Config.Reader.read!(Path.join(@root, "config/#{name}"), env: Mix.env(), target: :host)

        Config.Reader.merge(config, settings)
      end)

    Application.put_all_env(config)
  end
end

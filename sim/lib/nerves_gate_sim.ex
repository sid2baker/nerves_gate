defmodule NervesGateSim do
  @moduledoc "Development tools for disposable, supervised QEMU devices. No in-memory hardware backend."

  @source_dir Path.expand("..", __DIR__)

  @doc false
  def source_dir, do: @source_dir

  @doc false
  def script(name), do: Path.join(@source_dir, "priv/qemu/#{name}.exs")

  @doc false
  def configure do
    # Dependency config files are not imported by an application's Mix project.
    # Merge runtime settings before applying them so endpoint secrets don't
    # replace the adapter, PubSub and other host settings.
    config =
      Enum.reduce(["config.exs", "runtime.exs"], [], fn name, config ->
        settings =
          @source_dir
          |> Path.join("config/#{name}")
          |> Config.Reader.read!(env: Mix.env(), target: :host)

        Config.Reader.merge(config, settings)
      end)

    Application.put_all_env(config)
  end
end

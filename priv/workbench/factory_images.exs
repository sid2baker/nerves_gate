# Preloaded in an isolated EC100 Mix process. Resolve build metadata only;
# never start firmware applications, compile device code, or access USB.
defmodule Mix.Tasks.Dev.FactoryImages do
  use Mix.Task
  @requirements ["loadpaths"]
  @compile {:no_warn_undefined, [Nerves, Nerves.BuildPlan]}

  def run([]) do
    images =
      Nerves.build_plan()
      |> Nerves.BuildPlan.fetch_interpolated_env!("NERVES_SYSTEM")
      |> Path.join("images")

    IO.puts("FACTORY_IMAGES=" <> Base.encode64(images))
  end
end

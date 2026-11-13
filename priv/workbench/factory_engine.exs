# Resolve the selected system's source in an isolated target Mix process.
# Never compile device code, start firmware applications, or access USB.
defmodule Mix.Tasks.Dev.FactoryEngine do
  use Mix.Task

  def run([]) do
    target = Mix.target()
    app = String.to_existing_atom("nerves_system_#{target}")
    source = Mix.Project.deps_paths() |> Map.fetch!(app)
    task = Path.join(source, "lib/mix/tasks/#{target}.flash.ex")

    unless File.regular?(task), do: Mix.raise("The selected system has no factory flash engine")
    IO.puts("FACTORY_ENGINE=" <> Base.encode64(task))
  end
end

defmodule Mix.Tasks.Solution.New do
  use Mix.Task
  @shortdoc "Create a separate solution repository without platform dependencies"
  @requirements ["app.config"]
  def run(args) do
    {options, paths} = OptionParser.parse!(args, strict: [local_sdk: :boolean])

    case paths do
      [path] -> Dev.Solution.new!(path, options[:local_sdk] || false)
      _ -> Mix.raise("Usage: mix solution.new PATH [--local-sdk]")
    end
  end
end

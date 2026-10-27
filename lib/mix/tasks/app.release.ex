defmodule Mix.Tasks.App.Release do
  use Mix.Task
  @shortdoc "Plan or prepare first-party GitHub app releases; never publish"
  @requirements ["app.config"]

  def run(args) do
    {options, arguments, invalid} = OptionParser.parse(args, strict: [output: :string])
    root = Workbench.root()

    case {arguments, invalid} do
      {["plan", tag], []} ->
        info = Workbench.AppReleases.metadata!(tag, root)

        Mix.shell().info(
          "#{info.tag}\n\n#{info.notes}\n\nPlan only; no assets or publication. Prepare requires a clean committed checkout."
        )

      {["prepare", tag], []} ->
        output =
          options[:output] ||
            Mix.raise("Supply --output with a new directory outside the checkout")

        info = Workbench.AppReleases.prepare!(tag, root, output)

        if file = System.get_env("GITHUB_OUTPUT"),
          do: File.write!(file, "prerelease=#{info.prerelease}\n", [:append])

      {["integration", tag], []} ->
        Workbench.AppReleases.metadata!(tag, root)
        Workbench.Release.require_validation!(%{project: "."}, root)

      {["unpublished", tag], []} ->
        Workbench.AppReleases.metadata!(tag, root) |> Workbench.Release.unpublished!()

      {["verify", tag], []} ->
        Workbench.AppReleases.verify!(
          tag,
          root,
          options[:output] || Mix.raise("Supply --output with the prepared assets")
        )

      _ ->
        Mix.raise(
          "Usage: mix app.release plan|prepare|integration|unpublished|verify apps/APP/vX.Y.Z [--output DIRECTORY]"
        )
    end
  end
end

defmodule Mix.Tasks.Release.Check do
  use Mix.Task
  @shortdoc "Validate SDK or platform release metadata; never publish"

  def run(args) do
    {operation, tag} =
      case args do
        [tag] ->
          {"check", tag}

        [operation, tag] when operation in ~w(prepare dependencies unpublished verify) ->
          {operation, tag}

        _ ->
          Mix.raise("Usage: mix release.check [prepare|dependencies|unpublished|verify] TAG")
      end

    root = Path.expand("../../..", __DIR__)
    info = Dev.Release.metadata!(tag, root)

    case operation do
      "prepare" ->
        Dev.Release.prepare!(
          tag,
          root,
          System.fetch_env!("GITHUB_OUTPUT"),
          System.fetch_env!("NOTES_FILE")
        )

      "dependencies" ->
        Dev.Release.dependencies!(info, root)

      "unpublished" ->
        Dev.Release.unpublished!(info)

      "verify" ->
        Dev.Release.verify!(info, System.fetch_env!("NOTES_FILE"))

      "check" ->
        Dev.Release.dependencies!(info, root)
        Mix.shell().info("#{info.tag}\n\n#{info.notes}")
    end
  end
end

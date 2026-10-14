defmodule Mix.Tasks.Nerves.Artifact.Release do
  @moduledoc """
  Release tooling for the EC100 QEMU system, without compiling gateway firmware.

  Preload this host-only task so Nerves can run it before resolving artifacts:

      MIX_TARGET=x86_64 elixir -r dev/artifact_release.ex -S mix nerves.artifact.release plan

  `plan` is local and read-only. `check` checks GitHub and sets the Actions `publish`
  output. `publish` is restricted to the main-branch GitHub workflow.
  """
  use Mix.Task

  @requirements ["loadpaths"]
  # This task is preloaded before Mix puts the Nerves dependency on the code path.
  @compile {:no_warn_undefined, [Nerves, Nerves.Artifact.Archive]}

  @repo "sid2baker/nerves_gate"
  @app :nerves_system_ec100_qemu
  @notes_path "_build/system-release/notes.md"

  @impl true
  def run(["plan"]) do
    info = metadata!()
    Mix.shell().info("#{info.tag}\n#{info.download.filename}\n\n#{info.notes}")
  end

  def run(["check"]) do
    info = metadata!()
    publish? = release_state!(info) != :published

    Mix.shell().info(
      if publish?, do: "Build and publish #{info.tag}", else: "#{info.tag} is current"
    )

    if output = System.get_env("GITHUB_OUTPUT"),
      do: File.write!(output, "publish=#{publish?}\n", [:append])
  end

  def run(["publish"]) do
    unless System.get_env("GITHUB_ACTIONS") == "true" and
             System.get_env("GITHUB_REPOSITORY") == @repo and
             System.get_env("GITHUB_REF") == "refs/heads/main" do
      Mix.raise("Publication is restricted to the main-branch EC100 QEMU system workflow.")
    end

    info = metadata!()
    ensure_clean!()

    unless git!(["rev-parse", "HEAD"]) == System.fetch_env!("GITHUB_SHA"),
      do: Mix.raise("The checkout does not match the workflow commit.")

    if release_state!(info) != :published do
      publish!(info)
    end
  end

  def run(_), do: Mix.raise("Usage: nerves.artifact.release plan | check | publish")

  defp metadata! do
    unless Mix.target() == :x86_64,
      do: Mix.raise("Use MIX_TARGET=x86_64 from the application root.")

    package = Enum.find(Nerves.build_plan().packages, &(&1.app == @app))
    unless package, do: Mix.raise("EC100 QEMU system is missing from the Nerves build plan.")
    [download] = package.downloads
    check_locks!(package.path)
    notes = release_notes!(File.read!(Path.join(package.path, "CHANGELOG.md")), package.version)

    %{
      tag: "ec100-qemu-v#{package.version}",
      package: package,
      download: download,
      notes: notes
    }
  end

  defp check_locks!(system_path) do
    app_lock = Mix.Dep.Lock.read()
    system_lock = Mix.Dep.Lock.read(Path.join(system_path, "mix.lock"))

    for {dep, lock} <- Map.delete(system_lock, :nerves_system_linter) do
      unless app_lock[dep] == lock,
        do:
          Mix.raise("Align #{dep} in the application and system mix.lock files before releasing.")
    end
  end

  # The system changelog uses level-two version headings and level-three sections.
  # Fenced examples are deliberately disallowed so headings cannot be ambiguous.
  @doc false
  def release_notes!(changelog, version) do
    parsed = Version.parse!(version)
    unless parsed.pre == [] and parsed.build == nil, do: Mix.raise("Use a stable system version.")
    lines = String.split(changelog, "\n")

    if Enum.any?(lines, &String.starts_with?(&1, ["```", "~~~"])),
      do: Mix.raise("No fences in the system changelog.")

    prefix = "## #{version} - "
    matches = Enum.filter(lines, &String.starts_with?(&1, prefix))

    unless match?([_], matches),
      do: Mix.raise("Add exactly one #{version} changelog section with an ISO date.")

    [heading] = matches
    _ = heading |> String.replace_prefix(prefix, "") |> Date.from_iso8601!()

    notes =
      lines
      |> Enum.drop_while(&(&1 != heading))
      |> tl()
      |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
      |> Enum.join("\n")
      |> String.trim()

    if notes == "", do: Mix.raise("The #{version} changelog section is empty.")
    notes
  end

  defp release_state!(info) do
    ensure_tag_matches!(info)

    case release(info.tag) do
      nil ->
        ensure_pending_tag_matches_head!(info.tag)
        :new

      release ->
        verify_release!(release, info)

        case {release["draft"], asset(release, info)} do
          {true, _} ->
            ensure_pending_tag_matches_head!(info.tag)
            :draft

          {false, %{"state" => "uploaded", "digest" => "sha256:" <> _}} ->
            :published

          _ ->
            Mix.raise(
              "#{info.tag} has no matching artifact. Bump VERSION and add release notes for changed build inputs."
            )
        end
    end
  end

  defp verify_release!(release, info) do
    unless tag_exists?(info.tag) do
      Mix.raise("Fetch the existing #{info.tag} tag before proceeding.")
    end

    unless release["name"] == info.tag and release["body"] == info.notes and
             release["prerelease"] == false do
      Mix.raise("#{info.tag} release metadata differs from the changelog. Do not overwrite it.")
    end
  end

  defp ensure_tag_matches!(info) do
    if tag_exists?(info.tag) do
      sources = Enum.map(info.package.artifact_source_files, &Path.relative_to_cwd/1)

      case System.cmd("git", ["diff", "--quiet", "#{info.tag}^{commit}", "--" | sources]) do
        {_, 0} ->
          :ok

        {_, 1} ->
          Mix.raise(
            "System build inputs changed since #{info.tag}. Bump VERSION and add release notes."
          )

        _ ->
          Mix.raise("Cannot compare system inputs with #{info.tag}.")
      end
    end
  end

  defp ensure_pending_tag_matches_head!(tag) do
    # An interrupted publication must resume from its original source commit,
    # including inputs deleted since then, not attach new bytes to an old tag.
    if tag_exists?(tag) and git!(["rev-parse", "#{tag}^{commit}"]) != git!(["rev-parse", "HEAD"]),
      do: Mix.raise("Resume #{tag} from its original workflow commit; do not reuse the tag.")
  end

  defp publish!(info) do
    archive = info.download.archive_path
    unless File.regular?(archive), do: Mix.raise("Build #{info.package.app} before publishing.")
    :ok = Nerves.Artifact.Archive.validate(archive)
    digest = sha256(archive)

    unless tag_exists?(info.tag) do
      git!(["tag", info.tag, "HEAD"])
      git!(["push", "origin", "refs/tags/#{info.tag}"])
    end

    File.mkdir_p!(Path.dirname(@notes_path))
    File.write!(@notes_path, info.notes)

    unless release(info.tag) do
      gh!([
        "release",
        "create",
        info.tag,
        "--verify-tag",
        "--draft",
        "--latest=false",
        "--title",
        info.tag,
        "--notes-file",
        @notes_path
      ])
    end

    case asset(release(info.tag), info) do
      nil ->
        gh!(["release", "upload", info.tag, archive])

      %{"digest" => ^digest, "state" => "uploaded"} ->
        :ok

      _ ->
        Mix.raise("The draft already contains different artifact bytes. Refusing to overwrite.")
    end

    unless match?(%{"digest" => ^digest, "state" => "uploaded"}, asset(release(info.tag), info)),
      do: Mix.raise("Uploaded artifact digest does not match the local build.")

    gh!(["release", "edit", info.tag, "--draft=false", "--latest=false"])
    unless release_state!(info) == :published, do: Mix.raise("Release verification failed.")
    Mix.shell().info("Published and verified #{info.tag}")
  end

  defp sha256(path) do
    hash =
      Enum.reduce(
        File.stream!(path, 1_048_576),
        :crypto.hash_init(:sha256),
        &:crypto.hash_update(&2, &1)
      )

    "sha256:" <> Base.encode16(:crypto.hash_final(hash), case: :lower)
  end

  defp asset(release, info),
    do: Enum.find(release["assets"], &(&1["name"] == info.download.filename))

  defp release(tag) do
    {body, status} = System.cmd("gh", ["api", "repos/#{@repo}/releases/tags/#{tag}"])

    case {status, JSON.decode(body)} do
      {0, {:ok, %{"tag_name" => ^tag} = data}} ->
        data

      {_, {:ok, %{"status" => "404"}}} ->
        nil

      _ ->
        Mix.raise(
          "Cannot read GitHub release #{tag}; check authentication and GitHub availability."
        )
    end
  end

  defp tag_exists?(tag) do
    case System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"]) do
      {_, 0} -> true
      {_, 1} -> false
      _ -> Mix.raise("Cannot check release tag #{tag}.")
    end
  end

  defp ensure_clean! do
    unless git!(["status", "--porcelain", "--untracked-files=no"]) == "",
      do: Mix.raise("Refusing to publish from a modified checkout.")
  end

  defp git!(args), do: command!("git", args) |> String.trim()
  defp gh!(args), do: command!("gh", args ++ ["--repo", @repo])

  defp command!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> Mix.raise("#{command} failed (#{status}): #{output}")
    end
  end
end

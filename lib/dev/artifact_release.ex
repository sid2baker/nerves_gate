defmodule Mix.Tasks.Nerves.Artifact.Release do
  @moduledoc """
  Release tooling for both systems, without compiling gateway firmware.

  Preload this host-only task so Nerves can run it before resolving artifacts:

      cd firmware
      MIX_TARGET=x86_64 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/dev/artifact_release.ex -S mix nerves.artifact.release plan

  The tag comes from the system's `artifact_sites`, so downloads and publication
  cannot disagree. Changing it is a system build-input change.

  `plan` is local and read-only. `check` checks GitHub and sets the Actions `publish`
  output. `source` prefetches with Buildroot; `collect` collects its legal info
  and EC100 release assets after a standard Nerves artifact build. `publish` is
  restricted to the main-branch GitHub workflow.
  """
  use Mix.Task

  @requirements ["loadpaths"]
  # This task is preloaded before Mix puts the Nerves dependency on the code path.
  @compile {:no_warn_undefined, [Nerves, Nerves.Artifact.Archive, Nerves.Container]}

  @repo "sid2baker/nerves_gate"
  @systems [ec100: :nerves_system_ec100, x86_64: :nerves_system_ec100_qemu]
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

  def run(["source"]) do
    info = metadata!()
    buildroot!(info, :source)
  end

  def run(["collect"]) do
    info = metadata!()
    collect!(info)
  end

  def run(["publish"]) do
    unless System.get_env("GITHUB_ACTIONS") == "true" and
             System.get_env("GITHUB_REPOSITORY") == @repo and
             System.get_env("GITHUB_REF") == "refs/heads/main" do
      Mix.raise("Publication is restricted to the main-branch system workflow.")
    end

    info = metadata!()
    ensure_clean!()

    unless git!(["rev-parse", "HEAD"]) == System.fetch_env!("GITHUB_SHA"),
      do: Mix.raise("The checkout does not match the workflow commit.")

    if release_state!(info) != :published do
      publish!(info)
    end
  end

  def run(_),
    do: Mix.raise("Usage: nerves.artifact.release plan | check | source | collect | publish")

  # Nerves 2.0.0-pre.4 ignores build_runner_opts. Use its workspace and mounts
  # for ordinary Buildroot commands; do not implement another downloader.
  defp buildroot!(info, phase) do
    plan = Nerves.build_plan()
    {tool, image, downloads, _} = Nerves.Container.prepare_artifact_workspace!(plan, info.package)

    {script, targets} = buildroot_command(phase, info.package.app, info.download.filename)

    args =
      ["run", "--rm"] ++
        Nerves.Container.container_user_args(tool) ++
        Nerves.Container.work_mount_args(tool, info.package) ++
        Nerves.Container.download_mount_args(tool, downloads) ++
        [
          "--env",
          "NERVES_BR_DL_DIR=/workspace/dl",
          "--workdir",
          "/workspace/build",
          "--entrypoint",
          "/bin/sh",
          image,
          "-ec",
          script,
          "buildroot" | targets
        ]

    case System.cmd(tool, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("Buildroot #{phase} failed (#{status})")
    end
  end

  defp collect!(info) do
    unless match?({:unix, :linux}, :os.type()),
      do: Mix.raise("Source archive collection requires Linux")

    unless info.package.app == :nerves_system_ec100 and File.regular?(info.download.archive_path),
      do: Mix.raise("Build the EC100 artifact before collecting its sources")

    File.mkdir_p!("dist")

    unless File.ls!("dist") == [],
      do: Mix.raise("dist must be empty before collecting release assets")

    buildroot!(info, :collect)
    workspace = Nerves.Container.work_dir(info.package)
    File.cp!(Path.join(workspace, "build/#{info.download.filename}"), info.download.archive_path)
    [binary, sources, checksums] = Enum.map(info.assets, &Path.join("dist", &1))
    File.cp!(info.download.archive_path, binary)

    command!("tar", [
      "-czf",
      sources,
      "--exclude=nerves_system_br/buildroot",
      "-C",
      workspace,
      "build/legal-info",
      to_string(info.package.app),
      "nerves_system_br"
    ])

    for path <- [binary, sources],
        File.stat!(path).size >= 2_147_483_648,
        do: Mix.raise("#{path} exceeds GitHub's 2 GiB limit")

    File.write!(checksums, Enum.map_join([binary, sources], "\n", &checksum_line/1) <> "\n")
  end

  @doc false
  def buildroot_command(:source, app, _filename) do
    {"""
     /workspace/nerves_system_br/create-build.sh /workspace/#{app}/nerves_defconfig /workspace/build
     exec make source
     """, []}
  end

  def buildroot_command(:collect, _app, filename) do
    # Buildroot cannot collect notices/config from a prebuilt external toolchain.
    # Keep those installed files; do not maintain another compiler source list.
    {"""
     make legal-info
     mkdir -p legal-info/licenses/toolchain-external-custom legal-info/toolchain-external-custom
     cp -a host/opt/ext-toolchain/share/licenses/. legal-info/licenses/toolchain-external-custom/
     cp host/opt/ext-toolchain/ct-ng.config host/opt/ext-toolchain/ct-ng.defconfig legal-info/toolchain-external-custom/
     exec make system "$@"
     """, ["NERVES_ARTIFACT_NAME=#{String.trim_trailing(filename, ".tar.gz")}"]}
  end

  defp checksum_line(path),
    do: String.replace_prefix(sha256(path), "sha256:", "") <> "  " <> Path.basename(path)

  defp metadata! do
    app = @systems[Mix.target()] || Mix.raise("Use MIX_TARGET=ec100 or x86_64 from firmware/.")
    package = Enum.find(Nerves.build_plan().packages, &(&1.app == app))
    unless package, do: Mix.raise("#{app} is missing from the Nerves build plan.")
    [download] = package.downloads
    notes = release_notes!(File.read!(Path.join(package.path, "CHANGELOG.md")), package.version)

    %{
      tag: tag!(download.sites),
      package: package,
      download: download,
      assets: asset_names(package.app, download.filename),
      notes: notes
    }
  end

  @doc false
  def tag!(sites) do
    case for({:github_releases, @repo, options} <- sites, do: options[:tag]) do
      [tag] when is_binary(tag) -> tag
      _ -> Mix.raise("The system needs one #{@repo} GitHub release site with an explicit tag.")
    end
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
        ensure_pending_sources!(info)
        :new

      release ->
        verify_release!(release, info)

        cond do
          release["draft"] ->
            ensure_pending_sources!(info)
            :draft

          assets_uploaded?(release, info.assets) ->
            :published

          true ->
            Mix.raise(
              "#{info.tag} is missing required artifacts. Bump VERSION; never overwrite a published release."
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

  defp ensure_pending_sources!(info) do
    # Application-only dependency updates do not invalidate a published system.
    # Lock alignment matters only when building a new or unfinished release.
    check_locks!(info.package.path)

    if tag_exists?(info.tag) do
      verify_pending_sources!(info.tag, Path.relative_to_cwd(info.package.path))
    end
  end

  @doc false
  def verify_pending_sources!(tag, system_path, repository \\ ".") do
    # Compare the whole system tree so deletions cannot escape the current Nerves
    # source list. Unrelated publisher repairs need not move the original tag.
    # Run from firmware/: its lock and the repository's toolchain pins.
    sources = [system_path, "mix.lock", "../mise.toml"]

    case System.cmd("git", ["diff", "--quiet", "#{tag}^{commit}", "--" | sources],
           cd: repository,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_, 1} ->
        Mix.raise(
          "Pending #{tag} has different system sources, dependency locks or toolchain pins. Bump VERSION; do not reuse the tag."
        )

      _ ->
        Mix.raise("Cannot compare pending system inputs with #{tag}.")
    end
  end

  defp publish!(info) do
    archive = info.download.archive_path
    unless File.regular?(archive), do: Mix.raise("Build #{info.package.app} before publishing.")
    :ok = Nerves.Artifact.Archive.validate(archive)
    uploads = upload_paths!(info)
    digests = Map.new(uploads, fn path -> {Path.basename(path), sha256(path)} end)

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

    draft = await_release!(info.tag, "creation", fn _ -> true end)
    upload_assets!(info, draft, uploads, digests)
    gh!(["release", "edit", info.tag, "--draft=false", "--latest=false"])
    await_release!(info.tag, "publication", &(&1["draft"] == false))
    unless release_state!(info) == :published, do: Mix.raise("Release verification failed.")
    Mix.shell().info("Published and verified #{info.tag}")
  end

  defp upload_assets!(info, draft, uploads, digests) do
    # Validate every existing asset before uploading anything; resume only exact
    # bytes, including EC100's source archive and checksum manifest.
    for {name, digest} <- digests do
      case asset(draft, name) do
        nil -> :ok
        %{"digest" => ^digest, "state" => "uploaded"} -> :ok
        _ -> Mix.raise("The draft contains different bytes for #{name}. Refusing to overwrite.")
      end
    end

    for path <- uploads, is_nil(asset(draft, Path.basename(path))) do
      gh!(["release", "upload", info.tag, path])
    end

    uploaded = await_release!(info.tag, "upload", &assets_uploaded?(&1, info.assets))

    for {name, digest} <- digests do
      unless asset(uploaded, name)["digest"] == digest,
        do: Mix.raise("Uploaded #{name} digest does not match the local build.")
    end
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

  @doc false
  def asset_names(:nerves_system_ec100, filename) do
    sources =
      String.replace_prefix(
        filename,
        "nerves_system_ec100-portable-",
        "nerves_system_ec100-sources-"
      )

    [filename, sources, "SHA256SUMS"]
  end

  def asset_names(:nerves_system_ec100_qemu, filename), do: [filename]

  @doc false
  def assets_uploaded?(release, names) do
    Enum.all?(names, fn name ->
      match?(%{"state" => "uploaded", "digest" => "sha256:" <> _}, asset(release, name))
    end)
  end

  defp upload_paths!(info) do
    paths =
      if info.package.app == :nerves_system_ec100,
        do: Enum.map(info.assets, &Path.expand("dist/#{&1}")),
        else: [info.download.archive_path]

    for path <- paths do
      unless File.regular?(path), do: Mix.raise("Missing release asset #{path}")
    end

    if info.package.app == :nerves_system_ec100 do
      [system, sources, checksums] = paths

      expected =
        Enum.map_join([system, sources], "\\n", &checksum_line/1)

      unless String.trim(File.read!(checksums)) == expected and
               sha256(system) == sha256(info.download.archive_path),
             do: Mix.raise("EC100 release assets or SHA256SUMS do not match the build.")
    end

    paths
  end

  defp asset(release, name),
    do: Enum.find(release["assets"], &(&1["name"] == name))

  defp release(tag) do
    # The release-by-tag endpoint excludes drafts, including one just created.
    System.cmd("gh", ["api", "repos/#{@repo}/releases?per_page=100", "--paginate", "--slurp"],
      stderr_to_stdout: true
    )
    |> release_from_response!(tag)
  end

  # GitHub's release list can lag behind a successful write. Wait a bounded time
  # for the write to become visible; never repeat the write itself.
  defp await_release!(tag, step, visible?, attempts \\ 30) do
    release = release(tag)

    cond do
      release && visible?.(release) ->
        release

      attempts > 1 ->
        Process.sleep(2_000)
        await_release!(tag, step, visible?, attempts - 1)

      true ->
        Mix.raise("GitHub release #{tag} did not show the #{step} within 60 seconds.")
    end
  end

  @doc false
  def release_from_response!(response, tag) do
    with {body, 0} <- response,
         {:ok, pages} <- JSON.decode(body),
         true <- is_list(pages) and Enum.all?(pages, &is_list/1),
         releases = Enum.concat(pages),
         true <- Enum.all?(releases, &valid_release?/1) do
      case Enum.filter(releases, &(&1["tag_name"] == tag)) do
        [] -> nil
        [release] -> release
        _ -> Mix.raise("Multiple GitHub releases use #{tag}. Refusing to choose one.")
      end
    else
      _ ->
        Mix.raise(
          "Cannot read GitHub releases for #{tag}; check authentication and GitHub availability."
        )
    end
  end

  defp valid_release?(%{"tag_name" => tag, "draft" => draft, "assets" => assets})
       when is_binary(tag) and is_boolean(draft) and is_list(assets) do
    Enum.all?(assets, &match?(%{"name" => name} when is_binary(name), &1))
  end

  defp valid_release?(_) do
    false
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

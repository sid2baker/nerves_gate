defmodule Workbench.AppReleases do
  @moduledoc "Prepare immutable first-party app GitHub assets. Publication belongs to the protected workflow."
  alias NervesGate.Apps.Releases

  def metadata!(tag, root) do
    case String.split(tag, "/") do
      ["apps", app, "v" <> version] ->
        unless Releases.approved?(app) and Releases.valid_version?(version),
          do: raise("Unsupported app release tag")

        notes =
          Workbench.Release.notes!(
            File.read!(Path.join([root, "apps", app, "CHANGELOG.md"])),
            version
          )

        %{
          app: app,
          version: version,
          project: "apps/#{app}",
          tag: tag,
          notes: notes,
          prerelease: Version.parse!(version).pre != []
        }

      _ ->
        raise "Use apps/APP/vX.Y.Z for an approved first-party application"
    end
  end

  def prepare!(tag, root, output) do
    info = metadata!(tag, root)
    revision = clean_revision!(root)
    output = Path.expand(output)

    if String.starts_with?(output, Path.expand(root) <> "/"),
      do: raise("Release output must be outside the checkout")

    case File.mkdir(output) do
      :ok -> :ok
      _ -> raise "Use a new release output directory; existing outputs are never replaced"
    end

    source = Path.join(root, info.project)
    archive = Workbench.Applications.package!(source, fn _ -> :ok end, :temporary)

    try do
      bytes = File.read!(archive)
      {:ok, package} = NervesGateSDK.Package.read_binary(bytes)

      unless to_string(package.app) == info.app and package.version == info.version,
        do: raise("Tag and packaged application/version disagree")

      {:ok, manifest} = Releases.describe(package, bytes, revision)
      unless clean_revision!(root) == revision, do: raise("Source changed during packaging")
      File.write!(Path.join(output, manifest["archive"]), bytes, [:exclusive, :sync])

      File.write!(
        Path.join(output, Releases.manifest_name(info.app, info.version)),
        Jason.encode!(manifest, pretty: true) <> "\n",
        [:exclusive, :sync]
      )

      File.write!(Path.join(output, "release-notes.md"), info.notes, [:exclusive, :sync])
      Mix.shell().info("Prepared #{info.tag} at #{output}; nothing published")
      info
    after
      File.rm(archive)
    end
  end

  @doc false
  def clean_revision!(root) do
    {status, 0} =
      System.cmd("git", ["status", "--porcelain", "--untracked-files=normal"], cd: root)

    if status != "",
      do:
        raise(
          "App release assets require a clean committed checkout; commit only with separate authorization"
        )

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    String.trim(revision)
  end

  def verify!(tag, root, directory) do
    info = metadata!(tag, root)
    repo = Releases.repository()

    {json, 0} =
      System.cmd(
        "gh",
        ["api", "repos/#{repo}/releases/tags/#{URI.encode(tag, &URI.char_unreserved?/1)}"],
        stderr_to_stdout: true
      )

    release = Jason.decode!(json)

    unless release["tag_name"] == info.tag and release["name"] == info.tag and
             release["body"] == info.notes and
             release["draft"] == false and release["prerelease"] == info.prerelease,
           do: raise("Published app release metadata disagrees with canonical source")

    files = [
      Releases.archive(info.app, info.version),
      Releases.manifest_name(info.app, info.version)
    ]

    unless Enum.sort(Enum.map(release["assets"], & &1["name"])) == Enum.sort(files),
      do: raise("App release must contain exactly its archive and manifest")

    temp =
      Path.join(
        System.tmp_dir!(),
        "app-release-verify-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(temp)

    try do
      {_, result} =
        System.cmd("gh", ["release", "download", tag, "--repo", repo, "--dir", temp],
          stderr_to_stdout: true
        )

      unless result == 0,
        do: raise("Cannot verify public release assets; inspect the partial publication")

      for file <- files do
        unless File.read!(Path.join(directory, file)) == File.read!(Path.join(temp, file)),
          do:
            raise(
              "Published app asset bytes do not match #{file}; never replace them automatically"
            )
      end

      :ok
    after
      File.rm_rf!(temp)
    end
  end
end

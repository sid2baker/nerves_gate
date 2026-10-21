Code.require_file("../lib/package_release.ex", __DIR__)
alias NervesGateTools.PackageRelease
[action, tag] = System.argv()
root = Path.expand("../..", __DIR__)
info = PackageRelease.metadata!(tag, root)

case action do
  "prepare" ->
    PackageRelease.prepare!(
      tag,
      root,
      System.fetch_env!("GITHUB_OUTPUT"),
      System.fetch_env!("NOTES_FILE")
    )

  "dependencies" ->
    PackageRelease.dependencies!(info, root)

  "unpublished" ->
    PackageRelease.unpublished!(info)

  "verify" ->
    PackageRelease.verify!(info, System.fetch_env!("NOTES_FILE"))

  _ ->
    raise "Unknown release action #{action}"
end

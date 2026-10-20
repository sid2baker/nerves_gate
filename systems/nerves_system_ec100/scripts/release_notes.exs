# Only release the VERSION recorded in this checkout. Keep development builds
# untagged; published versions and their artifact filenames must stay immutable.
[tag] = System.argv()
version = File.read!("VERSION") |> String.trim()
parsed = Version.parse!(version)

# Monorepo tags are namespaced per package.
if tag != "system-ec100/v#{version}", do: raise("Tag #{tag} does not match VERSION #{version}")
if "dev" in parsed.pre, do: raise("Choose a release version instead of #{version}")

# CHANGELOG.md uses canonical `## VERSION - YYYY-MM-DD` headings. Read those
# sections directly rather than generating a second set of release notes.
sections =
  "CHANGELOG.md"
  |> File.read!()
  |> String.split("\n## ")
  |> Enum.drop(1)
  |> Enum.filter(&String.starts_with?(&1, "#{version} - "))

section =
  case sections do
    [section] -> section
    _ -> raise("Expected exactly one changelog section for #{version}")
  end

[date, body] = String.split(section, "\n", parts: 2)
date |> String.replace_prefix("#{version} - ", "") |> Date.from_iso8601!()
notes = String.trim(body)
if notes == "", do: raise("Release notes must not be empty")
IO.puts(notes)

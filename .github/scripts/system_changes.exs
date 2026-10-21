base =
  case System.get_env("EVENT_NAME") do
    "pull_request" -> System.fetch_env!("PR_BASE_SHA")
    "push" -> System.fetch_env!("PUSH_BASE_SHA")
    _ -> "HEAD"
  end

output = System.fetch_env!("GITHUB_OUTPUT")

for {name, system} <- [system: "nerves_system_ec100_qemu", ec100: "nerves_system_ec100"] do
  changed? =
    if base == String.duplicate("0", 40) do
      true
    else
      case System.cmd("git", ["diff", "--quiet", base, "HEAD", "--", "systems/#{system}"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> false
        {_, 1} -> true
        {error, code} -> raise "git diff failed (#{code}): #{error}"
      end
    end

  File.write!(output, "#{name}=#{changed?}\n", [:append])
end

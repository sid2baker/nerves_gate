# Elixir Design Review

A standalone skill for evidence-based review of Elixir design, contracts, and
OTP ownership. It reviews existing packages and subsystems, not only diffs.
It strongly favors removing unnecessary code and layers, preserves required
behavior, and reports findings before changing code. Added structure must have
a clear benefit over a smaller local fix; line reduction is evidence, not a quota.

## Use

Copy this directory into your agent's supported skills directory. Keep
`SKILL.md` and the `references/` directory together. No other skill, hook,
service, or extra dependency is required.

Example requests:

```text
$kata-ex-design-review Review this package for unnecessary complexity and
idiomatic Elixir/OTP. Read its guides and examples. Report; do not edit.

$kata-ex-design-review Review lib/my_app/worker.ex and its callers. Focus on
cancellation, state ownership, and cleanup.

$kata-ex-design-review Compare this branch with origin/main. apply:local
Apply verified defects and safe refinements; preserve public contracts.
```

The report separates defects, safe refinements, design decisions, and open
investigations. Each finding needs code evidence and a concrete next step.
The skill does not install tools, change branches, or publish results by default.

## Package lenses

The review reads `references/package-index.md` and selects package-specific
lenses from the target's locked dependencies and named scope. The package set
currently includes Phoenix, Ash, and Jido. Several lenses can apply to one
integration. Add another package by creating one file under
`references/packages/` and one detection row in the index.

Package lenses supply focused questions, not fixed conclusions. The installed
package source and official documentation for its locked version remain the
authority.

## Review teams

Broad package reviews use two or three native subagents when responsibilities
can be separated. Narrow reviews stay inline unless an independent check adds
clear value. One primary reviewer owns coverage, verification, and the final
assessment. Without subagent tools, the same work runs inline.

See [reviewer coordination](references/reviewer-coordination.md). The workflow
uses bounded assignments, independent first reads, and evidence-based synthesis.
It does not require a particular model, external review service, or JSON pipeline.
For mature packages, preserving a sound design and finding no needed change is a
successful outcome. Durable lessons include decisions to keep, not only defects.

## Further reading

These are optional public resources, not runtime dependencies or instructions
to invoke other skills. Verify advice against the project's installed versions.

- [Elixir anti-patterns](https://hexdocs.pm/elixir/what-anti-patterns.html):
  official guidance on code, design, and process choices.
- [Mix xref](https://hexdocs.pm/mix/Mix.Tasks.Xref.html): dependency analysis
  and the meaning of compile, export, and runtime edges.
- [usage_rules](https://hexdocs.pm/usage_rules/readme.html): package-maintained
  guidance for coding agents.
- [Elixir Forum skill collection discussion](https://elixirforum.com/t/elixir-skills-for-claude-cursor-codex/74180/):
  community skills, including dependency-cycle work.
- [Elixir review tools and skills discussion](https://elixirforum.com/t/elixir-rustler-rust-skills-for-claude/74724):
  analysis tools followed by contextual review of their findings.
- [Optimization and bug-finding prompts](https://elixirforum.com/t/prompting-agents-to-find-optimization-opportunities-and-bugs-in-elixir-codebases/76590):
  experimental prompts and discussion of evidence and verification.

## Maintenance checks

Use [the evaluation procedure](references/evaluation.md) to compare skill revisions.

When changing the skill, check these cases against its instructions:

| Case | Expected behavior |
| --- | --- |
| Named package with no diff | Trace every package responsibility; show coverage. |
| Repeat a package review | Keep full scope; verify old fixes and run fresh traces. |
| One boundary was fixed | Search sibling boundaries for the same assumption. |
| Built-in implementation passes | Check valid custom implementations at extension boundaries. |
| Process fails before a wait | Preserve queued failure evidence; inspect test barriers. |
| Pending coverage but tests pass | Continue review; do not issue a package-wide verdict. |
| Truncated tool output | Read the missing relevant sections before marking them traced. |
| Requested ref differs from checkout | Inspect that ref without mixing source versions. |
| Useful behaviour with one implementation | Assess its contract; do not delete by count. |
| Unmeasured performance concern | Label an investigation; do not claim a speedup. |
| Formatter and lint pass | Continue semantic review; do not invent style failures. |
| Checks are unavailable | Report limits; do not install tools automatically. |
| General cleanup request | Preserve APIs and feature scope. |
| No verified issue | Report no actionable findings. |

Also check frontmatter, relative links, and absence of private paths or chat data.

For a skill evaluation, retain the reviewed revision, coverage table, concrete
probes, missed findings, and rejected hypotheses outside the published skill.
Compare runs by contract coverage and reproducible findings, not finding count,
report length, or test count. Treat these cases as acceptance criteria; reading
them is not a substitute for testing the skill on another package.

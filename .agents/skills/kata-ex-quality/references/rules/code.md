# Code rules

Load this file for `focus:code` or when configured duplication or reachability
evidence applies.

## Dead-code analyzer

The bundled analyzer builds transitive reachability from source AST and declared
production roots. It does not use project dependencies. Copy
`assets/dead-code-roots.exs` to `.kata/dead-code-roots.exs` only in record or
apply mode and only when the project needs a roots file. Preserve an existing
file. In scan mode, select an existing roots file or use the bundled template
without writing the project.

The roots file is data, not executable configuration. Use a literal map with
optional `public_api: ["path"]` and
`roots: [{"path or glob", "reason"}]` entries. Use each key at most once and
use only strings. Function calls, variables, and interpolation are invalid.

```text
elixir <quality-skill-directory>/scripts/dead_code.exs --root <project> --roots .kata/dead-code-roots.exs --json
```

JSON output needs Elixir 1.18 or later. Text output works on earlier supported
versions. Read [the analyzer limits](../dead-code-analysis.md) before confirming
or removing a candidate.

## `duplicate-code` version 2

- **Use when:** A configured clone detector or direct inspection confirms a
  clone.
- **Default class:** `judgment-required`. Reclassify as `safe-refinement` only
  when direct evidence identifies one stable owner and satisfies every safety
  condition in the skill contract.
- **Detect:** Use the configured baseline when present and inspect every clone in
  context. Record the count, limit, and remaining headroom. A passing limit does
  not prove that each clone has a stable shared owner.
- **Finding:** One clone group has the same responsibility and changes together.
- **Fix:** Reuse the current owner or extract the smallest stable function.
- **Protect:** Behavior, public API, and configured clone baseline.
- **Verify:** Focused tests and clone gate pass without a new dependency cycle.
- **Judgment stop:** Similar syntax represents distinct policy, has no stable
  abstraction owner, crosses a package or process boundary, or changes public
  errors, data, or wire behavior.
- **Batch key:** Clone group and responsibility owner.

## `confirmed-dead-code` version 2

- **Use when:** Reachability evidence identifies an unused module or group.
- **Detect:** Start from declared production and public roots, then use
  transitive source reachability. Inspect quoted code and `__using__`,
  `__MODULE__` aliases, behaviours and implementations, protocols, runtime
  configuration, telemetry handlers, supervision children, `Module.concat`,
  persisted module names, framework conventions, Mix tasks, application startup,
  package contents, and downstream entry points. Tests, self-references, docs,
  and incoming edges from another dead group do not establish production life.
  Treat an uncalled public module as advisory until external use is resolved.
- **Finding:** One transitive production group has no supported static, dynamic,
  public, or external consumer.
- **Fix:** Remove one confirmed group and its dedicated tests, configuration,
  aliases, and docs. Edit a mixed test file only at the removed subject.
- **Protect:** Public entry points, dynamic consumers, macro injection,
  protocols, behaviours, application startup, package contents, and component
  coverage rules.
- **Verify:** Reachability analysis, warning-as-error compilation, formatting,
  focused and required tests, application-start or integration checks for
  runtime wiring, and package gates pass. Judge configured floors instead of an
  unprotected raw coverage change.
- **Judgment stop:** Roots are incomplete, external or dynamic use remains
  possible, or removal changes a supported API.
- **Batch key:** Reachable module group.

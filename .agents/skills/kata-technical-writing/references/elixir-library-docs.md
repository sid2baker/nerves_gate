# Write Elixir library documentation

Use this reference only for public Elixir or Hex package documentation. It
applies to package READMEs, HexDocs guides, `@moduledoc`, `@doc`, `@typedoc`,
behaviour documentation, public errors, and package changelog entries. Follow
the project's current documentation rules when they are more specific.

## Select the publication layer

Keep each fact at the layer where its reader needs it:

- A package README and HexDocs explain one independently usable package.
- An ecosystem site explains how several packages work together.
- Contributor documents explain workspace commands, internal paths, release
  work, and maintenance rules.

Do not put workspace-only dependencies, commands, paths, or unpublished APIs in
public package documentation. Link between layers instead of copying the same
guide into each layer.

## Write the package entry point

The first sentence of a package README must let an Elixir developer identify
the kind of library, the problem it solves, and whether it applies to their
work. Prefer a specific outcome over a broad quality claim.

Use this order when it helps the package reader:

1. Package name and specific purpose.
2. The result or code shape that the package makes possible.
3. The package's role in its ecosystem and important package relationships.
4. Installation from the supported public source.
5. One complete quick start that shows the core value.
6. When to use the package, its material limits, and important alternatives.
7. Links to HexDocs, longer guides, examples, contribution rules, and license.

Omit a section when it adds no value. Do not force every package into the same
template. For a high-level package, state whether it works alone or assumes an
existing application or another package.

## Build useful examples

Progress from the smallest working example to the common case, failure handling,
configuration, and advanced integration. Use realistic modules, values, and
results. Do not use names such as `Foo`, `data`, or `some_value` when a concrete
domain name makes the example clearer.

Public examples must use public package dependencies and normal Mix commands.
Take versions, defaults, options, and requirements from current package sources.
Do not copy version numbers from an old guide. Mark a partial snippet and say
where it belongs. Prefer complete examples that compile, run, or work as
doctests.

Show the expected result. When a before-and-after comparison explains the
value, keep both examples equivalent and verify both claims.

## Document the public API

A useful `@moduledoc` states:

- what the module does;
- when and why a developer uses it;
- one complete example; and
- non-obvious options, limits, or extension points.

A useful `@doc` starts with the function's action. It then states when to use
the function, what it returns, and the errors or edge cases that affect the
caller. Add an IEx example when it proves behavior.

Do not repeat the function name or list obvious parameters. Document an option
when its meaning, default, unit, interaction, or failure behavior is not clear
from the type and name.

Treat public types and behaviours as API documentation:

- Give each public type a `@typedoc` that states what it represents and where
  callers use it.
- Prefer named types to unexplained maps and tuples in public examples.
- Explain when each callback runs, what it can return, and which callbacks are
  optional.
- Include one complete implementation for an extension behaviour when the
  contract is not obvious.

## Treat failures as documentation

For a public error or error document, state:

1. What failed.
2. What the library expected.
3. What it received when that information is safe to show.
4. What the developer can change to fix the problem.
5. Where to find more detail when the fix is complex.

Write changelog entries with the affected symbol, observable change, and user
impact. Replace claims such as "improved performance" with a measured result or
remove the claim.

## Verify the published result

Use the package source as the authority for versions, defaults, supported
platforms, options, and status. Check that public docs contain no internal paths
or workspace-only commands.

Run the checks that the package already provides. These can include `mix docs`,
doctests, documentation tests, link checks, and a clean Mix project that uses
the public package. Confirm that the README quick start also works in the
published documentation environment.

Check ExDoc configuration, source links, release tags, public types, callbacks,
and guide registration when they are in scope. Report each example or command
that could not run. Do not present an untested example as verified.

Do not import another project's fixed frontmatter, site paths, dependency
versions, status labels, calls to action, or code-fence rules. Read those values
from the target project's current rules.

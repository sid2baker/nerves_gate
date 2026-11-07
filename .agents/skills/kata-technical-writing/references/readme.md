# Write a README

Use this reference when the selected target is one `README.md`. The caller or
request must decide the target path. If the task must decide which root or
nested README files the project needs, return that decision to the project
orientation workflow.

## Establish the contract

Identify the README's audience, purpose, scope, source facts, and next action.
State what the reader probably knows when they arrive. Read the existing
README, package or application metadata, common scripts, relevant CI, and the
local contribution, security, license, and documentation entry points. Inspect
only the sources needed for the selected README.

Preserve badges, notices, attribution, public links, generated sections, and
published anchors unless the request and evidence support their change.

## Use an entry-point structure

A root README usually needs this order:

1. Project name and one clear statement of its category, purpose, and intended
   reader.
2. Material status, audience, or support limits when readers need them early.
3. The smallest verified install, setup, or usage path that produces a useful
   result.
4. Common run, test, or development commands.
5. A short map of non-obvious entry points when it saves reader effort.
6. Links to detailed docs, contribution rules, security policy, and license.

Use only the sections that help the target reader. Do not add empty headings or
template text.

A nested README states what the subtree does, how it relates to the parent,
which local setup or commands apply, and where the reader goes next. Do not
repeat the root README.

A `docs/README.md` is usually an index for the documentation system. Follow its
local document rules instead of the root README order.

## Make the working path true

- State the working directory and prerequisites when they are not obvious.
- Give commands in the order that a new reader can run them.
- Show the expected result when success is not visible from the command.
- Check each command against scripts, configuration, CI, tests, or direct
  execution. Do not claim that an unrun command passed.
- Use realistic names and data. Keep examples consistent with current names,
  options, defaults, and public interfaces. Mark a partial example as
  illustrative.
- Test the quick start from a clean environment when practical. Record the
  preconditions when a clean test is not possible.
- Link to detailed reference instead of copying it into the README.

Do not use the README as a changelog, roadmap, full API reference, repository
dump, or general knowledge base unless the project already makes it the owner
of that content.

Replace vague value claims with supported behavior or remove them. Do not add
performance, maturity, production-use, or adoption claims without current
evidence.

## Verify the README

Check local links, anchors, image paths, badges, code fences, commands, examples,
counts, status claims, and protected content. Run the narrowest safe command
that proves the working path. Inspect the final README as a new reader and
confirm that the first useful action is easy to find.

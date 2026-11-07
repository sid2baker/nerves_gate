---
name: kata-technical-writing
description: Write, review, or clean one selected technical artifact from verified source facts. Use for drafting, prose quality, or an explicit request to remove AI writing patterns; use project orientation to choose README files and Docs Kata maintenance to correct code drift.
metadata:
  schema: kata.skill/v1
  subject: technical-communication
  practice: write
  object: technical-document
  profile: bounded-execution
  authority: local-write
  consumes: "technical-writing-request, source-material, readme-brief"
  produces: "technical-document, verified-readme, writing-review, revised-prose, verified-change"
---

# Technical writing

**Outcome:** The target reader receives one accurate technical document or one
evidence-based writing review that serves its stated purpose.

**Done:** The selected scope is complete, material claims match source evidence,
the structure fits the document type, applicable language and repository rules
pass, and each local edit is ready for review or commit.

## Assignment

The required inputs are one target document or review, its reader, its purpose,
and the source facts needed for accuracy. A `readme-brief` can supply the path,
audience, required content, protected material, and verification needs.

Direct user authority or inherited caller authority permits a response-only
review or local edits to the named writing scope. Do not change code, product
behavior, unrelated documents, staged state, Git history, or remote state. A
commit-message request produces message text. It does not create a commit. Ask
when missing product intent changes what the document must say.

Read active project instructions, the existing target when present, its local
index or template, and the sources for material claims. Preserve useful
structure, established terms, attribution, notices, and unrelated edits.

Identify what the target reader already knows, why they opened the document,
and the first result they need. Start at that point. Do not teach background
that the selected reader already needs as a prerequisite.

## Select the document type

For a README, read and follow
[references/readme.md](references/readme.md). A README is an entry point. It can
combine a short explanation, a working path, and lookup details in separate
sections.

For an Elixir package README, HexDocs guide, module or function document,
public type, behaviour, or library error message, also read and follow
[references/elixir-library-docs.md](references/elixir-library-docs.md).

For another document, choose one dominant mode:

- **Tutorial:** Help a learner produce a visible result through ordered steps.
- **How-to:** Help a competent reader complete one task.
- **Reference:** State current facts, options, limits, and errors for lookup.
- **Explanation:** Help the reader understand one bounded topic and its reasons.

Follow an established project template for an RFC, decision record, issue, pull
request, or commit message. A pull-request description is a short reviewer
brief. A commit message states the change and its reason. These artifacts do
not need a documentation mode.

A review-only request produces findings and proposed text without changing the
target.

For an explicit request to remove AI writing patterns, also read and follow
[references/remove-ai-patterns.md](references/remove-ai-patterns.md). Preserve
the source meaning, claims, audience, and tone. Do not use that mode to change
the argument or add unsupported facts.

## Write for the reader

- Lead with the result, purpose, or first useful action. Put the common case
  before exceptions and background.
- Use current source evidence for behavior. Use an accepted decision for
  intent. State a conflict instead of choosing one.
- Replace broad praise with observable behavior, an exact limit, or a supported
  example. Do not add a benchmark, status, or adoption claim without evidence.
- Use active voice and direct commands. Put a condition before the action it
  controls.
- Use short, familiar words. Remove filler, repeated meaning, generic praise,
  excess hedging, and abstract metaphors.
- Use the exact project term, path, command, flag, symbol, and UI label. Do not
  rename one thing as the text continues.
- Give one instruction or thought per sentence. Split a sentence when its parts
  can be acted on or judged separately.
- Keep modifiers next to the words they change. Make each pronoun point to one
  clear noun. Repeat the noun when needed.
- Do not call a task simple, easy, obvious, or quick. Do not use "please" in an
  instruction or "click here" as link text.
- Use sentence-case headings without skipped levels. Use numbered lists for
  sequences and bullets for sets. Keep list items parallel.
- Put code, paths, commands, flags, and symbols in code font. Keep examples
  small enough to check. Use realistic names and data, and show the expected
  result when the example demonstrates behavior.

If an interface is difficult to explain accurately, report the interface
problem. Do not hide a design problem with more prose.

Do not follow a language rule when it makes the sentence less accurate or less
natural. Rewrite the sentence or keep the clearer form.

## Work in passes

1. List the reader's starting point, task, and material claims that need
   evidence.
2. Choose the smallest structure that supports that task.
3. Draft with the useful result early, exact project terms, and working
   examples.
4. Check facts, commands, paths, links, counts, examples, and expected results.
5. Remove each sentence that does not help the reader act or understand.
6. Read the final document aloud or from a new reader's point of view. Repair
   abrupt transitions, repeated sections, hidden assumptions, and ambiguity.

## Verify and report

Run the narrowest available check for changed links, commands, examples, or
generated content. When practical, follow a changed procedure or quick start
from a clean state. Do not install a checker only for this edit. Inspect the
final diff and confirm that it contains only the selected writing scope.

For an edit request, fix in-scope defects and repeat affected checks before
handoff. A review-only request ends with the review. Report unmet conditions
and limits. Do not claim that an incomplete document is complete.

Report the document type, target, sources checked, files changed, checks run,
unverified claims, and unresolved intent. Produce `verified-readme` only when a
README edit passes its specific checks. Produce `verified-change` only when a
local edit remains and all applicable checks pass. A review-only route produces
`writing-review`.

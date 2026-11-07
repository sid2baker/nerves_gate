# Set up Docs Kata

Use this route to establish the Docs Kata structure and collect existing,
unprocessed documentation. Do not rewrite, classify, or claim to verify the
collected content.

## Inspect and select

- Inventory prose and supporting assets in project documentation locations.
  Search links and build configuration for consumers. An extension or category
  folder does not prove documentation status or prior review.
- Preserve root entry points, policies, licenses, changelogs, all agent
  instruction files, generated or vendored documents, installed skills, and
  separate repositories. Exclude source, tests, fixtures, and dependencies. Do
  not follow symbolic links outside the project.
- Include unprocessed category documents on first setup. On repeats, retain
  inbox contents and processed documents. Preserve and report documents whose
  prior setup state is unclear.
- Retain files needed at fixed paths by builds, websites, published URLs, or
  package consumers unless the same change preserves those uses. Log each
  exception and reason.
- Show a short inventory and proposed moves before the writes. Setup authority
  permits routine in-scope moves. Ask only about a content, behavior,
  instruction, or required-path conflict.

## Create and collect

1. Create missing `docs/AGENTS.md`, `docs/README.md`, and
   `docs/inbox/README.md`. Use `../templates/docs-agents.md` for new
   instructions. Otherwise, preserve existing rules and merge one reusable
   `## Docs Kata` section. Never silently replace a conflicting rule.
2. Preserve useful index content. Link to the rules, inbox, existing processed
   documents, and fixed-path exceptions. Add a missing documentation index link
   to the root README. Create category folders only during processing.
3. Preserve the intake log. Record original path, actual destination, intake
   date, status, and exceptions with reasons.
4. Map individual inventoried files into `docs/inbox/`, preserving each source
   path relative to the project root. Reserve setup and instruction files.
   Exclude the inbox; never move a directory into itself or its descendants.
5. Check each destination. Never overwrite or discard either file. Choose a
   free numeric suffix for a collision and record the actual destination.
6. Record a content hash before each move. Move the current file, including
   local edits, and verify its content at the destination. Never restore from
   Git or stage changes automatically.
7. Repair affected relative links in moved and referring files, including
   assets, fragments, and reference-style links. Preserve external URLs. Limit
   content changes to path repairs. Leave a document in place if a required
   consumer cannot be preserved, and log why.
8. Record completed moves. After an interruption, reconcile sources,
   destinations, and intake records before continuing. Preserve differing
   copies.

Verify that the setup files agree, every inventoried item is moved, retained, or
unresolved, assets and local edits are accounted for, and a repeat is safe.
State that inbox contents still need review.

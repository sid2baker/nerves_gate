# Create a project verification skill

Use this Create specialization when a project needs one local skill that starts
and drives its real user surface and saves observable proof.

## Inspect the project

Read the repository before asking the user. Determine:

- the primary user surface, such as a web UI, CLI, desktop app, API, or library;
- the documented local start command, required data, authentication, ports, and
  usable-ready signal;
- the existing driving method, such as Playwright, a PTY, `curl`, or a project
  test harness;
- observable evidence, such as screenshots, transcripts, responses, logs, exit
  codes, files, or database state; and
- isolation controls for ports, data directories, profiles, and processes.

Use the active host's documented project skill root. Create one package named
`verify-<app>`. Do not create copies for hosts that are not in use. If the base
application does not build or start, report that blocker unless its repair is
part of the assignment.

## Write the package

The generated `SKILL.md` must contain current, repository-specific instructions
with no placeholders:

- **Launch:** Exact start command, usable-ready check, and teardown. Include
  migrations or seed steps needed from an empty isolated data directory.
- **Doctor:** One read-only check for the correct process, build, port, data,
  and authentication state.
- **Drive:** The real harness commands and stable selectors or prompts. Do not
  use coordinates or tab order when stable handles exist.
- **Evidence:** Capture the user action and resulting state. Check visible and
  durable side effects. A dry-run name is not proof that files, Git, browser,
  or network state stayed unchanged.
- **Cleanup:** Stop only processes started by the run. Remove scratch state but
  preserve proof artifacts.
- **Helpers:** Show how to run each included helper.

Create a small feature map with the top three to five user paths. For each
feature, state how a user reaches it, how the harness drives it, the observable
passing state, and known preconditions. Do not weaken a path when seed data or
another precondition is missing.

## Prove the package

Run the generated instructions end to end for one mapped feature: launch,
doctor, drive, capture evidence, and clean up. Confirm that the evidence remains
after cleanup. Run cleanup after a failed attempt so no process or port remains.

A package that was not run is a draft. If the proof used a stand-in environment,
list each setup step that the real target still needs to verify.

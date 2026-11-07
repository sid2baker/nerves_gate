# Build a local application harness

Use this method when the accepted work result is a local harness that can drive
and inspect an interactive application. Do not load it only to run an existing
harness; that is verification work.

## Contract

Name the application command or local URL, the interaction to drive, the
observable state to capture, the allowed local effects, the cleanup boundary,
and the next verifier. Prefer a repository harness before new code.

Select the smallest available capability:

- For a CLI or TUI, use the repository test or demo driver, a PTY, or an owned
  terminal session.
- For a web application, use the installed browser test or automation support.
- For an IDE, Electron, or Chromium application, use its supported automation
  or debug interface and select the page by a stable application marker.

Do not add a project dependency only to make a temporary probe unless the
assignment requires a reusable harness and permits the dependency.

## Build loop

1. Create the smallest isolated workspace and deterministic input.
2. Start the application with the documented local command. Record the process,
   port, profile, environment facts, and candidate identity.
3. Capture the initial terminal screen or page structure.
4. Perform one action. Wait for an observable prompt, state, event, or page
   condition instead of using a fixed sleep when a stable signal exists.
5. Capture the result, logs, and any requested profile artifact.
6. Stop the application and remove temporary sessions, profiles, ports, files,
   and private artifacts. Report anything that remains.

Use roles, labels, stable data attributes, prompts, or output patterns before
coordinates or tab order. Refresh the observed structure after navigation or a
large state change. Do not send credentials or destructive commands into the
harness. Keep private screenshots, transcripts, and heap data only with
explicit authority.

The handoff identifies the harness, candidate state, start command, driven
actions, expected observations, cleanup command, known simulation boundaries,
and fast local check. It does not claim that application behavior passed.

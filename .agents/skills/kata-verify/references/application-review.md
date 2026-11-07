# Verify an interactive application

Use this method when an existing local harness can drive a CLI, TUI, browser,
IDE, or Electron candidate. If no suitable harness exists and creating one
needs a durable target change, return Unknown and send a bounded harness request
to the work owner.

1. Identify the candidate, harness, documented start command, local workspace,
   expected behavior, and cleanup boundary. State which application parts and
   external services are real, simulated, or unavailable.
2. Start from a clean disposable state. Record the process, port, profile,
   viewport or terminal size, and environment facts that can change behavior.
3. Capture the initial terminal screen, accessibility tree, DOM structure, or
   other direct application state.
4. Perform one action at a time. Re-read the current structure after navigation
   or a material state change. Wait for a concrete prompt, state, event, or page
   condition instead of an arbitrary delay.
5. Compare the observed result with the acceptance condition. Screenshots and
   transcripts can support behavior evidence, but appearance alone does not
   prove a behavior and does not authorize visual-design judgment.
6. Repeat timing-dependent or state-dependent behavior enough to show its
   observed rate. Use the benchmark method for a numeric performance claim.
7. Stop the application and remove temporary sessions, profiles, files,
   processes, ports, recordings, and private artifacts. Report any residue.

Prefer roles, labels, stable application markers, prompts, and output patterns
over coordinates, tab order, or stale element handles. Do not enter credentials
or destructive commands. Do not retain private screenshots, transcripts, heap
snapshots, or request data without explicit authority.

Return Pass only when the real driven path produced every material observable
result. Return Fail for a proved mismatch, Unknown when the harness or boundary
cannot reach the condition, and Blocked when the check needs unavailable access
or authority. Send visual-design quality and design changes to Impeccable.

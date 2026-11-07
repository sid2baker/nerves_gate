# Supervision modes

Select one mode from the request. State the mode before supervision begins.

| Mode | Permitted behavior | Stop condition |
| --- | --- | --- |
| `check` | Inspect current state once and report progress, evidence, and blockers. | One status report. |
| `watch` | Use available wait or monitoring tools and report meaningful changes. | Completion condition, material blocker, cancellation, or resource limit. |
| `drive` | Watch, coordinate authorized follow-up, return failed work for repair, and check the next return. | Checked return ready for integration, material blocker, cancellation, or resource limit. |

## Rules

- A status question selects `check` unless the caller already authorized a
  continuing `watch` or `drive`.
- A later status question does not cancel an active authorized watch.
- Watching permits observation. It does not grant corrective work, messages,
  retries, publication, or changes to authority.
- Driving permits only follow-up already inside the assignment authority.
- A changed scope, new recipient, new resource limit, or consequential decision
  returns to its owner.
- Use the host's wait or notification mechanism when available. Do not create a
  recurring automation or background service for a finite active assignment.
- Check whether an uncertain submission or start succeeded before retrying.
- In `drive`, do not retry an unchanged failure. Select another authorized
  approach. Stop at a checked return, an explicit review point, cancellation,
  a resource limit, or a specific blocker. Do not broaden `check` or `watch`
  into repair.
- A checked return completes the delegated unit. The integration owner keeps
  responsibility for any larger requested outcome.

Report the last observed state, new evidence, stop reason, and next owner. Do
not report unchanged polls as progress.

# Diagnose a failed agent run

Use this method when the observed failure belongs to an agent execution rather
than only to the software that it changed or called.

## Capture

Record the task identity, requested result, expected result, observed result,
last supported success, failed or repeated tool sequence, relevant supplied
context, current working state, host and model facts when available, and the
stop condition that should have applied. Redact credentials, private data,
access-bearing URLs, and unrelated prompt content.

Treat the agent's final explanation and self-report as claims. Use tool output,
saved artifacts, current state, and replay evidence to support them.

## Diagnose

Classify the first failed boundary as one of these types:

- request: the goal, scope, acceptance condition, or authority was missing or
  interpreted incorrectly;
- context: required evidence was absent, stale, conflicting, or displaced by
  low-value context;
- selection: the agent chose the wrong route, method, tool, or target;
- execution: a tool call, command, state transition, or retry policy failed;
- environment: the current files, branch, process, service, quota, or access did
  not match the supported assumption;
- stop: the agent looped, declared success too early, or did not hand off when
  the required evidence or authority was unavailable.

Trace the complete chain from the request or environment trigger to the first
invalid decision or state, its propagation through later actions, and the final
wrong result. A repeated error message or a large token count is a symptom, not
the cause.

## Recover and repair

Use one small reversible action to test the diagnosis: restate the active goal,
reload current state, narrow to one failing action, replace a retry with one
discriminating probe, or stop at the correct authority boundary. A successful
retry is contained recovery. It is not proof of a durable repair.

A verified repair needs a fixed replay case or another repeatable check that
fails before the change and passes after it. Fix the owning prompt, skill,
configuration, harness, tool boundary, or code only when the assignment grants
that authority. Do not claim repair when only the current conversation state
changed or the original run cannot be replayed.

Report the capture, failure class, causal chain, recovery action, replay result,
durable repair when authorized, remaining uncertainty, and the prevention seam.

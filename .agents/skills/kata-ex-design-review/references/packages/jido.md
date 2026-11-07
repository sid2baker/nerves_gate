# Jido design review lens

Apply this lens to the installed `jido`, `jido_action`, `jido_ai`, and `req_llm`
versions. Read local dependency source before making an API claim; older examples
can use obsolete namespaces and runtime contracts.

## Actions and execution

- A `Jido.Action` owns one operation with explicit input, output, error, context,
  and effect contracts. Check that its schema matches the repository's current
  Zoi or NimbleOptions style.
- Distinguish direct `run/2` behavior from `Jido.Exec` behavior. Validation,
  lifecycle hooks, retry, timeout, and execution options need tests at the
  execution boundary.
- An action can perform immediate I/O when the workflow needs the result. Use a
  runtime effect or directive when the effect does not need an immediate result.
- Keep tool-callable inputs JSON-compatible, narrowly described, and validated.
  Verify the tool schema through the installed adapter.

## Agent state and commands

- Separate the pure agent value from its runtime process. Review `new/1` and
  `cmd/2` contracts before AgentServer behavior.
- The agent returned by `cmd/2` already contains completed internal state. A
  directive is not an internal state update.
- Use `Jido.Agent.StateOp` values for strategy-owned state changes and
  `Jido.Agent.Directive` values for runtime-owned external effects. Flag the old
  `Jido.Directive` namespace only when the locked version confirms it is obsolete.
- Review signal routes for one clear owner. Static routes belong in module
  configuration; runtime-dependent routes need a concrete reason to be dynamic.
- A plugin must own a reusable capability, including its state, actions, and
  routes. Check state-key and route collisions across plugins.

## Runtime and signal flow

- Trace `Jido.Signal` creation, routing, `AgentServer.call/2` or `cast/2`, command
  execution, directives, and the final observable result.
- Do not treat an action tuple as an AgentServer signal. Do not add a process when
  pure `cmd/2` behavior is sufficient.
- For schedules, sensors, child agents, pods, partitions, persistence, and custom
  runtimes, identify the state and lifecycle owner, supervisor, restart behavior,
  registration, cleanup, and recovery source.
- Compare completion before and during waits, owner or worker death, timeout,
  cancellation, duplicate signals, stale messages, and restart.
- Check directive execution for ordering, idempotency, backpressure, bounded
  concurrency, and safe error reporting.

## Jido AI and tools

- Select the smallest surface that satisfies the contract: direct generation,
  an AI action, a tool-using agent, or a standalone reasoning runtime.
- Keep model aliases and provider secrets in runtime configuration. Do not encode
  a universal provider or model default in reusable library code.
- Review tool allowlists, tool context, request transforms, structured output,
  streaming, checkpoint, and resume behavior against the locked versions.
- Treat filesystem, shell, network, and data-changing tools as high risk. Check
  authorization, input validation, timeout, and failure mapping at the action
  boundary.
- Check authentication errors, rate limits, invalid output, partial streams, tool
  errors, and redaction of prompts, responses, tokens, and provider logs.

## Tests and evidence

- Test action domain behavior directly, then use `Jido.Exec` only for execution
  contracts that it owns.
- Test agent state, state operations, and directives through `new/1` and `cmd/2`.
  Start AgentServer only for signals, timers, directives, supervision, registration,
  or process lifecycle.
- Use monitors, messages, or repository polling helpers for asynchronous work.
  Avoid fixed sleeps when a deterministic synchronization point exists.
- Use deterministic provider adapters, local HTTP stubs, schema checks, and
  request-shaping tests for AI code. Live providers require explicit authority.
- Check one real runtime wiring path when the reviewed contract depends on the
  configured Jido instance or supervision tree.

Do not recommend another layer only to wrap Jido types. A wrapper must protect a
stable application contract, enforce policy, or isolate an effect.

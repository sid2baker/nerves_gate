---
name: kata-build-jido
description: Build or change Jido actions, agents, runtime behavior, tests, and AI integrations with current local contracts. Use for implementation and regression work in the Jido Elixir ecosystem.
metadata:
  schema: kata.skill/v1
  subject: software-engineering
  practice: implement
  object: jido-system
  profile: bounded-execution
  authority: local-write
  consumes: "jido-change-request, elixir-repository"
  produces: "verified-change"
  language: elixir
---

# Build Jido

**Outcome:** A small Jido change uses the target repository's current APIs,
keeps state and effects at the correct boundary, and has focused tests.

**Done:** The requested action, agent, runtime, AI, or test contract is complete;
focused success and failure tests pass; required repository checks pass or have
reported limits; and the local change is ready for review or commit.

## Assignment

The required inputs are one Jido change request and its target Elixir
repository. Direct user authority or inherited caller authority permits local
source, test, fixture, and configuration-template edits inside that request.
Do not install dependencies, stage, commit, push, publish, store credentials,
use a live provider, or change remote or live state. HTTP, database, file,
shell, provider, and other external effects need authority from the task and a
clear owner. Ask when the effect or runtime boundary is unclear.

## Inspect the target

Read the active instructions, `mix.exs`, locked dependency versions, nearby
Jido modules, supervision code, configuration, and tests. Search the installed
`jido`, `jido_action`, `jido_ai`, and `req_llm` source for the exact API that the
change needs. Do not use a remembered example when local source differs.

Record the requested public input, output, errors, state, signals, effects,
provider use, and test boundary before you edit code. Select the smallest
surface that owns the behavior:

- a `Jido.Action` for one validated operation or tool;
- a `Jido.Agent` for pure state, command, action, route, or directive behavior;
- `Jido.AgentServer` for signals, timers, supervision, registration, delivery,
  or another process concern;
- `Jido.AI` helpers, actions, or agents for model work;
- tests only when the request is to prove existing behavior.

Use more than one surface only when the requested behavior crosses those
boundaries.

## Build actions

Keep one action focused on one operation. Follow the repository's current
schema style. Add an `output_schema` when callers or tools need a checked output
shape. Implement `run/2` with a supported result:

```elixir
{:ok, result}
{:ok, result, effects}
{:error, reason}
```

Use the context as a map. In an agent command, current state is available at
`context[:state]`. Do not assume that another key exists unless the caller sets
it. Use `Jido.Exec.run/3` when validation, hooks, retries, timeouts, or execution
options are part of the contract. A direct `run/2` call tests only the callback.

An action can perform immediate I/O when the workflow needs its result. Use a
runtime boundary or directive for an outbound effect that does not need an
immediate result. For an AI tool, use a stable name, clear descriptions, a
narrow schema, and values that can become JSON. Check the installed tool
adapter API instead of copying an old `to_tool/0` example.

## Build agents and runtime behavior

Define agents with the current `Jido.Agent` contract. Use static
`signal_routes` in the module options. Use `signal_routes/1` only when the route
depends on runtime context. For pure command behavior:

```elixir
agent = MyAgent.new()
{agent, directives} = MyAgent.cmd(agent, {MyAction, %{value: 1}})
```

The returned agent already contains its completed state. Directives do not
update that state. Use `Jido.Agent.StateOp` structs for agent state changes and
`Jido.Agent.Directive` structs for runtime-owned effects. Check the installed
struct fields. Do not use the old `Jido.Directive` namespace.

Send a `Jido.Signal` to current `Jido.AgentServer.call/2` or `cast/2` functions.
Do not send an action tuple to those runtime functions. Use `cmd/2` for direct
action execution. Add plugins only for a reusable capability that owns its
state, actions, and routes. Add sensors, schedules, child agents, partitions,
or persistence only when the request needs that runtime feature.

## Build AI behavior

Select the smallest current Jido AI surface. Use a direct generation helper for
one request, an AI action inside an existing workflow, `Jido.AI.Agent` for a
tool-using loop, and a lower runtime only when streaming, checkpoint, or resume
behavior needs it.

Keep provider secrets in runtime configuration. Use a repository model alias
when one exists. Do not add a universal model default. Restrict tool exposure to
the request that needs it. Treat filesystem, shell, network, and data-changing
tools as high risk, and validate input at the action boundary.

Handle authentication errors, rate limits, timeouts, invalid structured output,
partial streams, and tool errors in the repository's normal error form. Do not
write secrets, prompts, responses, tokens, or sensitive request logs to Git.

## Test at the lowest reliable layer

Use these layers in order:

1. Call an action callback directly for domain behavior.
2. Use `Jido.Exec` for validation, hooks, retries, timeouts, or execution options.
3. Use an agent module's `new/1` and `cmd/2` for state, state operations, and directives.
4. Start `Jido.AgentServer` for signals, directives, timers, children,
   supervision, registration, or process lifecycle.
5. Use provider adapters, fixtures, or local stubs for AI behavior.

Test public results and effects. Cover valid input, validation failure through
the correct boundary, domain errors, and output shape. For agents, cover initial
state, command results, state operations, and directives. For AI work, cover
tool schemas, request shape, structured-output validation, and error mapping.

Use monitors, messages, or repository polling helpers for asynchronous work.
Do not use a fixed sleep when a deterministic synchronization point exists.
Clean up started processes and temporary resources. Keep live providers out of
the default suite. Run one only when the user requests it and supplies an
approved credential path.

## Verify

Run the focused test first. Run concurrency tests more than once. Then run the
repository's documented checks. When no stronger command is documented, run
the applicable focused test, `mix compile --warnings-as-errors`, and `mix test`.

Fix failures caused by the change and rerun the affected checks. Before you
retry an unchanged failure, investigate its cause or select another in-scope
approach. If a required check cannot run within the assignment limits, report
the unmet condition and the recovery attempted.

Report the contract, selected Jido boundary, state and effect choices, test
layers, commands, offline or live provider use, and each API assumption that
you could not verify.

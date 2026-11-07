# Elixir package lens index

Use package lenses in addition to the general review lenses. They refine the
questions for installed frameworks; they do not replace contract tracing,
evidence, or verification.

## Select lenses

Inspect `mix.exs`, `mix.lock`, application configuration, module names, and the
review scope. Read only the matching package files:

| Evidence in the target | Lens |
| --- | --- |
| `phoenix`, `phoenix_live_view`, controllers, LiveViews, channels, plugs, endpoints, or routers | `packages/phoenix.md` |
| `ash`, `ash_postgres`, `ash_sqlite`, `ash_authentication`, `ash_phoenix`, Domains, resources, actions, or policies | `packages/ash.md` |
| `jido`, `jido_action`, `jido_ai`, `req_llm`, Jido agents, actions, signals, directives, plugins, or AgentServer code | `packages/jido.md` |

Several lenses can apply. For example, a Phoenix adapter that calls an Ash code
interface needs both the Phoenix and Ash lenses. A Jido agent exposed through a
Phoenix channel needs both the Jido and Phoenix lenses.

Read the installed package source and official documentation for the locked
version before making a version-sensitive claim. Treat a lens as a question set,
not proof that the target is wrong.

## Add a package lens

Add one file under `references/packages/<package>.md`. Keep it focused on:

- public contracts and framework-required exposure;
- ownership of data, processes, effects, and failure handling;
- lifecycle and concurrency rules;
- integration boundaries with callers and adapters;
- the smallest tests or probes that verify those contracts;
- common false positives that reviewers must avoid.

Add one detection row to this index. Do not add package-specific rules to the
main skill when a separate lens can own them.

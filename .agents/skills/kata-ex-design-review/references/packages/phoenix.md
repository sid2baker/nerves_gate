# Phoenix design review lens

Apply this lens to the installed Phoenix and LiveView versions. Verify exact
callbacks, configuration, and lifecycle rules against local dependency source or
official documentation.

## Web boundary

- Treat controllers, LiveViews, components, plugs, channels, and API handlers as
  adapters. They normalize transport input, call an application operation, and
  translate a stable result.
- Check that web modules do not own durable business rules, authorization policy,
  database transitions, or external-service workflows that another entry point
  can bypass.
- Trace actor and tenant data from authentication through the application call.
  Compare browser, API, socket, channel, job, and internal entry points.
- Keep transport errors separate from application errors. Confirm that expected
  validation, forbidden, not-found, conflict, and unavailable results map to the
  intended HTTP, socket, or navigation behavior.
- Check that public maps, assigns, session values, and serialized payloads do not
  expose secrets, internal structs, policy details, or partially loaded data.

## Router, plug, and endpoint design

- Verify pipeline order and scope. A plug in one browser pipeline does not protect
  an API route, channel, LiveView mount, or background path.
- Check that endpoint, router, and plug configuration has one owner. Avoid copied
  gates and environment rules that can drift.
- Confirm that request identifiers, telemetry metadata, proxy headers, host rules,
  body limits, and parsers match the actual deployment boundary.
- Treat a large router as a navigation concern only when it causes real ownership
  or policy duplication. File length alone is not a finding.

## LiveView and channel lifecycle

- Separate disconnected render from connected mount. Verify that authorization
  and data loading happen at the correct phase and cannot be bypassed after connect.
- Identify the source of truth for durable state. Socket assigns are view state,
  not a second durable owner.
- Check `handle_event`, `handle_info`, async work, subscriptions, uploads, and
  navigation for stale messages, duplicate effects, cancellation, and cleanup.
- Do not run long or blocking work in the LiveView or channel process when latency,
  mailbox growth, or failure isolation requires another boundary.
- Verify PubSub topic construction, subscription ownership, message shape, and
  behavior after reconnect or process restart.

## OTP and supervision

- Review Endpoint, PubSub, Presence, telemetry, task supervisors, and custom
  children as one supervision design. Record restart and shutdown expectations.
- A web process must not become the owner of durable work only because it received
  the request. Move work only when another process has a real lifecycle contract.
- For tasks and jobs, check concurrency limits, idempotency, retry, terminal
  failure, and observability.

## Persistence and external effects

- Trace transaction boundaries through the context or application API. A
  controller or LiveView must not assemble a multi-write invariant ad hoc.
- Keep external effects on the deliberate side of database commit. Check retries
  for duplicate email, payment, notification, and webhook effects.
- Check preloads, pagination, deterministic ordering, and query count at the web
  boundary. Do not require a view struct unless it protects a stable contract.

## Tests and evidence

- Use controller, ConnCase, LiveView, channel, and integration tests at the
  narrowest layer that proves the contract.
- Test allowed, forbidden, unauthenticated, malformed, stale, reconnect, and
  duplicate-event paths when they apply.
- Use monitors, messages, or controlled adapters for asynchronous work. Do not
  use a fixed sleep when a deterministic barrier exists.
- Verify one real production wiring path. A mocked adapter success does not prove
  router, endpoint, supervision, or authorization integration.

Do not report framework conventions as defects only because plain Elixir could
use fewer modules. Require a reachable failure, bypass, ownership conflict, or
specific maintenance cost.

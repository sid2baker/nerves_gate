# NervesGate QEMU Control

A standalone host OTP application for managing local NervesGate QEMU gateways.
It has no dependency on the gateway application or its Nerves runtime stack.

From the repository root, start it with:

```sh
mix nerves_gate.dev
```

Then open `http://qemu.localhost:4000/`.

The root `mix nerves_gate.qemu ...` task delegates lifecycle and observation
commands to this project. Observations accept only the versioned,
secret-free `nerves_gate.status.v3` gateway API. When working here directly,
use `mix qemu ...`. Run `mix nerves_gate.qemu help` from the repository root,
or `mix qemu help` in this project, for the complete command list.

Use `mix nerves_gate.qemu setup --rebuild --count 3` to build firmware from the
current checkout, recreate all QEMU disks from that artifact, and start them.
This intentionally erases the gateways' persisted `/data` settings.

## Automated commissioning and resilience tests

Provide a reusable, pre-authorized key through the environment or the
repository root's ignored `.env` file:

```sh
NERVES_GATE_TAILSCALE_AUTH_KEY=tskey-auth-...
```

Then run from the repository root:

```sh
mix nerves_gate.qemu commission
mix nerves_gate.qemu integration --count 3 --rebuild
```

`commission` starts and heals the existing topology, invokes each gateway's
public backend commands through its local JSON transport, and waits for
Internet, Tailnet, cluster, and DeviceState mesh convergence. It does not start
a browser or inspect rendered forms. `integration` optionally performs a fresh
firmware build and disk reset first, then runs all resilience scenarios.
Set `NERVES_GATE_QEMU_CLUSTER_GROUP` or pass `--group NAME` to override the
default `nerves-gate-integration` group.

The suite verifies a fully replicated mesh, heartbeat-based offline detection
within ten seconds of uplink loss, disconnect/reconnect healing, retained
last-known snapshots, hard-restart boot-ID resynchronization, and stop/start
persistence without recommissioning, plus automatic rollback of an unkept scoped
settings update. Cleanup restores every VM and QMP link. The auth key is held
only long enough to submit the Tailnet backend command; it is never persisted or
included in diagnostics.

Requirements: QEMU, `fwup`, and Tailnet grants for gateway-to-gateway TCP `80`,
`4369`, and `43769`.

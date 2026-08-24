# NervesGate QEMU Control

A standalone host OTP application for managing local NervesGate QEMU gateways.
It has no dependency on the gateway application or its Nerves runtime stack.

From the repository root, start it with:

```sh
mix nerves_gate.dev
```

Then open `http://qemu.localhost:4000/dev/qemu`.

The root `mix nerves_gate.qemu ...` task delegates lifecycle and observation
commands to this project. Observations accept only the versioned,
secret-free `nerves_gate.status.v1` gateway API. When working here directly,
use `mix qemu ...`.

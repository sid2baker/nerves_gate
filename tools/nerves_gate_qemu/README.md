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
secret-free `nerves_gate.status.v2` gateway API. When working here directly,
use `mix qemu ...`. Run `mix nerves_gate.qemu help` from the repository root,
or `mix qemu help` in this project, for the complete command list.

Use `mix nerves_gate.qemu setup --rebuild --count 3` to build firmware from the
current checkout, recreate all QEMU disks from that artifact, and start them.
This intentionally erases the gateways' persisted `/data` settings.

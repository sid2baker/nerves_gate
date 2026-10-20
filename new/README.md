# NervesGateNew

Mix archive for creating portable Nerves Gate applications:

```console
mix archive.install hex nerves_gate_new
mix nerves_gate.new my_app
cd my_app
mix deps.get
mix test
mix nerves_gate.sim --firmware path/to/nerves_gate.fw
mix nerves_gate.sim.install
mix nerves_gate.package
```

The generator does not fetch dependencies or start devices. Generated applications
use `nerves_gate_sdk ~> 1.0`, plus `nerves_gate_sim ~> 1.0` as a development-only
tool. The simulator runs real Nerves Gate firmware in QEMU; there is no fake SDK
backend. The SDK supplies `mix nerves_gate.package`; production archives never
contain the simulator. See the generated README for lifecycle and storage
requirements.

To build the archive from source, run `mix archive.build` in this directory.
This package has its own VERSION and CHANGELOG; releases use `new/vX.Y.Z` tags.

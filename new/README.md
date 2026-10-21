# NervesGateNew

Mix archive for creating Nerves Gate app-development workspaces:

```sh
mix archive.install hex nerves_gate_new
mix nerves_gate.new my_workspace
cd my_workspace
mix setup
mix sim
# Start devices and commission application storage in their gateway UI.
# In another terminal:
mix app.install my_app
mix app.new telemetry
mix setup
mix test
mix app.package telemetry
```

The workspace owns simulator configuration and development tools. It contains
one initial app under `apps/my_app/`; additional apps are independent Mix
projects, not umbrella children. Each app depends only on `nerves_gate_sdk`.
`nerves_gate_sim` and generator helpers are workspace-only tooling, never part of
a device application's production package.

Generation does not fetch dependencies, boot devices or format cards. `mix setup`
fetches workspace and app dependencies, then downloads and SHA-256-verifies the
pinned QEMU firmware when the default image is missing. Existing images are reused
without HTTP requests. Custom paths in `config/simulator.exs` must be supplied by
the developer and are never populated with the default image. `mix sim` starts a
site with stopped QEMU devices and requires the host QEMU tools. There is no fake SDK backend and no copied firmware implementation.

`mix app.package` writes an app's standard OTP `.ez` archive under `packages/`.
`mix app.install` installs a temporary package into the workspace's existing
simulator session. An app name may be omitted when only one app exists.

See [Application development](https://github.com/sid2baker/nerves_gate/blob/main/docs/app-development.md).
Building the archive from source uses `mix archive.build` in this directory.
Hex installation requires the packages to be published; no publication happens
as part of generation or repository setup.

This package has its own VERSION and CHANGELOG; releases use `new/vX.Y.Z` tags.

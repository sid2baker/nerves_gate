# Distributed Workbench refactor

## Implemented shape

- One hidden session BEAM, owned by flock and MuonTrap. The simulator runs locally.
- `Workbench.Gateways` is the only directory. Owned QEMU, mDNS, Tailnet and manual
  addresses are candidates; cookie connection and compiled firmware identity checks
  promote them to verified gateways. Disconnected entries retain last-seen time.
- Simulated and physical gateways share `GatewayLive` and device-owned projection
  subscriptions. Ownership gates QEMU faults, disks and lifecycle, not reachability.
- Mix clients and Pi attach over distribution. There is no internal HTTP control
  API, CLI socket, legacy routing alias or intermediate launcher BEAM.
- `Workbench.Jobs` serializes long jobs and immutable one-use reviews. Runner
  reserves lifecycle/shutdown until each job worker exits; device reservations
  remain independent for scenarios and QEMU development installs.
- Physical new-application installation is reviewed, transferred over distribution,
  checked by the device and left stopped/disabled. Existing applications are rejected.
  QEMU development installs may explicitly start/upgrade under device reservation.
- Firmware review binds the exact image to serial/boot, health, immutable plugin
  artifacts and verified SSH trust. SSH uploads once; distribution verifies a new
  healthy boot. Unknown outcomes never authorize retry.
- Simulator starts directly from the written image and provisions through
  distribution. There is no boot-time A/B re-upload.
- Physical readiness, Ethernet/4G failover and button-reboot checks are a separate
  explicit scenario catalogue, run one at a time. Fixture controls remain QEMU-only.
- Factory provisioning retains destructive confirmation, backups and mandatory
  readbacks. Successful storage write is not reported as healthy boot; the gateway
  must later join the directory and be inspected separately.

## Removed

Competing discovery/device/mesh caches, Operations, generic SSH evaluation, HTTP
clients/API/CSRF harvesting, split physical LiveView, console command task, separate
simulator node, bootstrap firmware upload and post-flash USB HTTP heuristics.
No compatibility adapters or alternate identity protocols are retained.

## Qualification

Host checks and live checks are separate. Source tests cannot establish QEMU
bootstrap, A/B recovery, real electrical behavior, physical flashing or independent
management during failover. None of those operations is implicitly authorized by
this refactor. Full operator-owned CI and physical operations require their own scope.

Current operation and source ownership are documented in
[architecture](docs/architecture.md), [development](docs/development.md),
[firmware updates](docs/firmware-updates.md) and
[management networking](docs/qemu-management-network.md).

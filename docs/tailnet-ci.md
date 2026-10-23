# Real Tailscale authentication in QEMU

The manually dispatched **QEMU integration** workflow has an optional main-branch
**Tailscale authentication** job using the protected `tailnet-ci` GitHub environment.
Enable the **tailscale** input to run it. It never runs automatically on pushes or
pull requests.
Ordinary **Run all** and `mix test.qemu` selections exclude `tailscale_auth`;
select it explicitly to enroll real test devices.

The scenario uses the three-device configuration in `priv/simulator/tailnet.exs`. Each guest
enrolls through `NervesGate.remote_connect/2`. In CI,
`Tailscaled.Testing.auth_key/1` creates a different single-use, ephemeral,
pre-approved key for each guest through GitHub OIDC. Unused keys expire after ten
minutes. No reusable auth key or OAuth secret is stored in GitHub or simulator
configuration. The runner never joins the tailnet or changes its networking.

The scenario checks authenticated/online state, three distinct Tailscale IPv4
addresses and tagged node IDs, all six directed guest-to-guest HTTP paths to port
4000, and the same IP/node ID and working peer HTTP after one guest power cycle.
Node IDs come from each owned guest's LocalAPI, not the tailnet management API.
This does not test HTTPS Serve certificates, subnet routing/NAT, IPv6, or direct
versus DERP path selection. The ordinary `tailscale_login` scenario remains an
unenrolled URL/invalid-key check.

## One-time setup

Use a **dedicated test tailnet**. The gateway UI on port 4000 is unauthenticated;
these test nodes must not have access to production devices.

### 1. Restrict the test tag

Define `tag:ci` and allow only the traffic needed by this scenario. For a new
isolated test tailnet, the relevant policy is:

```json
{
  "tagOwners": {"tag:ci": ["autogroup:admin"]},
  "grants": [
    {"src": ["tag:ci"], "dst": ["tag:ci"], "ip": ["tcp:4000"]}
  ]
}
```

Do not replace an existing production policy with this example. Adding this grant
does not undo broader existing grants or the default allow-all ACL: remove those
in the isolated test tailnet if they would allow CI access beyond this rule.
No SSH, distribution, route approval, or policy-edit permission is needed.

### 2. Use the shared Tailscale OIDC trust credential

The credential is shared by `sid2baker` repositories. In **Settings → Trust
credentials**, configure its OpenID Connect trust as:

| Setting | Value |
| --- | --- |
| Issuer | GitHub Actions (`https://token.actions.githubusercontent.com`) |
| Subject | `repo:*` |
| **Required custom claim** `repository_owner_id` | `79519556` |
| Scope | **Auth keys: write** (`auth_keys`) |
| Permitted tag | `tag:ci` |

The owner-ID claim restricts the wildcard to repositories owned by `sid2baker`.
**Never use `repo:*` without that claim.** GitHub's newer subjects include immutable
owner/repository IDs, so a name-only pattern such as `repo:sid2baker/*` does not
match them. Matching the owner claim supports both subject formats without
hardcoding each repository's ID.

Do not add `nerves_gate`-specific repository or workflow-path claims to this shared
credential: they would exclude other repositories. This repository uses
`workflow_dispatch`; other consumers may use different events, so avoid shared
event restrictions that would exclude them. Every consuming repository must
protect its own credential-bearing jobs; this
workflow limits the job to `main` and the protected `tailnet-ci` environment.
Do not grant `all`, policy editing, or route-management scopes. This scenario needs
no `devices:core` permission; remove it from the shared credential only if no other
consumer needs it.

Copy the credential's **Client ID** and **Audience**. They are identifiers, not
long-lived authentication secrets. If token exchange fails, the credential details
show the received subject and exact validation error. Never print the JWT itself.

### 3. Configure the GitHub environment

In `sid2baker/nerves_gate`, open **Settings → Environments**:

1. Create `tailnet-ci`.
2. Restrict deployment branches to `main`; optionally require a reviewer.
3. Add environment secrets:
   - `TS_OAUTH_CLIENT_ID`: the generated Client ID.
   - `TS_AUDIENCE`: the generated Audience.

The job sets `TS_TAGS: tag:ci`. Do not add an auth key, OAuth secret or reusable API
token. OIDC token issuance is enabled only in this job with `id-token: write`.
Open **Actions → QEMU integration → Run workflow**, select `main` and enable
**tailscale**. Approve the `tailnet-ci` environment if required. Authentication
runs after the ordinary QEMU scenarios pass.
Missing credentials or failed enrollment fail the scenario rather than skipping it.

## Run locally

In the test tailnet's **Settings → Keys**, create a **Reusable**, **Ephemeral**,
**Pre-approved** key with `tag:ci`. Reusable is needed because three guests enroll
with it. Choose the shortest practical expiry and revoke it when finished; logout
does not revoke a reusable key.

Load it securely into `TAILSCALED_TEST_AUTH_KEY` in the shell that starts `mix dev`.
Do not put its value in shell history, simulator configuration or a committed file.
Start the session with the three-device configuration:

```sh
mix dev --config priv/simulator/tailnet.exs
```

Choose **Start devices** on the Simulator page. In another terminal:

```sh
mix test.qemu --only tailscale_auth
```

The scenario uses fresh disks and reserves all three devices. The key is read by
the running session, not the attaching `mix test.qemu` client: restart `mix dev` after
changing its key or configuration. With no local key, the helper attempts GitHub
OIDC and reports missing settings outside CI. Do not use `--ci` to start another
local bench.

## Cleanup and safety

Before attempting each enrollment, the scenario registers a cleanup callback for
that guest. On normal completion or a test failure, cleanup calls
`Tailscaled.logout/0` and waits for `needs_login`. Logout removes an ephemeral node
immediately. A cleanup failure fails the run and blocks the devices until Reset.
There is no management-API deletion, resource journal or key revocation step.

Forced cancellation or a killed worker can prevent cleanup. Reset the disposable
devices to erase enrollment, or stop them to take them offline. Tailscale normally
removes offline ephemeral nodes after 30–60 minutes; still-online nodes do not age
out. Unused CI auth keys expire after ten minutes. Nodes use a random `ng-test-`
prefix printed by the scenario; inspect that run's nodes if cleanup was interrupted,
and never delete unrelated devices. Key creation and enrollment are never retried
after an unknown outcome.

Generated JWTs, API tokens and CI auth keys stay in process memory and are masked
by `Tailscaled.Testing` in GitHub logs. Do not enable HTTP/request tracing or tee
this job's stdout into files: masking commands themselves contain credential values.
The job uploads no raw daemon logs, VM disks, or identity files, and caches only
verified downloads. Ordinary simulator diagnostics remain credential-free.

References: [Tailscaled.Testing](https://hexdocs.pm/tailscaled_ex/Tailscaled.Testing.html),
[ephemeral nodes](https://tailscale.com/kb/1111/ephemeral-nodes),
[workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation),
[GitHub immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

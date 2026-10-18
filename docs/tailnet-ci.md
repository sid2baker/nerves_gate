# Real Tailscale authentication in QEMU

**Simulator CI** runs the **Tailscale authentication** job automatically on pushes
to `main`, after the ordinary simulator checks pass. The job uses the protected
`tailnet-ci` GitHub environment and never runs for pull requests. No separate
workflow or manual trigger is needed.

Local `mix test` / `mix ci` selections remain credential-free and exclude
`tailscale_auth`; the CI job selects it explicitly.

It starts the dedicated three-device configuration in `dev/tailnet.exs`. Each
guest enrolls through `NervesGate.remote_connect/2` with a different single-use,
ephemeral, pre-approved auth key that expires after ten minutes. GitHub OIDC
creates a temporary Tailscale API token; no reusable auth key or OAuth client secret
is stored in GitHub or simulator configuration. The runner itself never joins
the tailnet or changes its networking.

The scenario checks authenticated/online device state, three distinct Tailscale
IPv4 addresses and node registrations, all six directed guest-to-guest HTTP paths
to port 4000, and retained identity/connectivity after one guest power cycle.
This is not a test of HTTPS Serve certificates, subnet routing/NAT, IPv6, or direct
versus DERP path selection. The ordinary `tailscale_login` scenario remains an
unenrolled URL/invalid-key check.

## One-time setup

Use a **dedicated test tailnet**. The gateway UI on port 4000 is unauthenticated;
these test nodes must not have access to production devices.

### 1. Restrict the test tag

In the test tailnet's access-control policy, define `tag:ci` and allow only the
traffic needed by this scenario. For a new isolated test tailnet, the relevant
policy is:

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
| Scopes | **Auth keys: write** (`auth_keys`) and **Devices → Core: write** (`devices:core`) |
| Permitted tag | `tag:ci` |

The owner-ID claim restricts the wildcard to repositories owned by `sid2baker`.
**Never use `repo:*` without that claim.** GitHub's newer subjects include immutable
owner/repository IDs, so a name-only pattern such as `repo:sid2baker/*` does not
match them. Matching the owner claim supports both subject formats without
hardcoding each repository's ID.

Do not add `nerves_gate`-specific repository or workflow-path claims to this shared
credential: they would exclude other repositories. Remove any old
`event_name: workflow_dispatch` restriction: automatic CI uses the `push` event.
Every consuming repository must protect its own credential-bearing jobs; this
workflow limits the job to `main` and the protected `tailnet-ci` environment. Do not
grant `all`, policy editing, or route-management scopes. Device-core permission is needed to verify registrations
and delete test nodes deterministically.

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

Do not add an auth key, OAuth secret or reusable API token. OIDC token issuance is
enabled only in this workflow's job with `id-token: write`.

## Run and inspect

Push to `main` and inspect **Actions → Simulator CI → Tailscale authentication**.
Approve the environment if required. To start the complete CI manually, use
**Actions → Simulator CI → Run workflow** with `main` selected.

The OIDC preflight runs before the Tailscale job builds firmware or enrolls guests.
Missing settings, claim mismatches and insufficient permissions fail the job,
never silently skip it.

The scenario is shared with the existing runner, but credential acquisition is
intentionally limited to GitHub Actions. Do not run `--ci` locally or paste keys
into the simulator. Local manual enrollment can still use the gateway UI's browser
login or a separately generated one-off key.

## Cleanup and safety

The scenario's cleanup callback and an `always()` workflow step delete only its
recorded ephemeral `tag:ci` nodes and revoke its recorded auth keys. Names include
the GitHub run ID/attempt, and `_build/qemu-tests/ng-ci-<run>-<attempt>.json` records
only those names and key IDs, never credential values. Failed cleanup fails CI and
keeps this journal for inspection. Key creation and enrollment are never automatically
replayed after an unknown outcome; cleanup can safely repeat deletion of these exact
owned resources.

Abrupt runner loss or forced cancellation can prevent cleanup. Ephemeral nodes
then expire after inactivity, and unused auth keys expire after ten minutes. An
unknown key-creation response can also leave an unrecorded key until that expiry;
creation is never replayed to discover its value.
Inspect nodes with the run's `ng-ci-<run>-<attempt>-` prefix in Tailscale if needed;
never delete unrelated CI nodes or assume revoking a key deletes its devices.

Generated JWTs, API tokens and auth keys stay in process memory and are masked in
GitHub logs. Do not enable HTTP/request tracing or tee the Tailscale job's stdout
into files: GitHub masking commands themselves contain credential values. This job
uploads no raw daemon logs, VM disks, or identity files, and caches only verified
downloads. The ordinary simulator job retains its credential-free diagnostics.

References: [workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation),
[trust-credential scopes](https://tailscale.com/kb/1623/trust-credentials),
[GitHub immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

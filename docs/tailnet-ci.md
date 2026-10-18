# Real Tailscale authentication in QEMU

The **Tailnet authentication** GitHub workflow is manual, main-branch-only and
uses the `tailnet-ci` GitHub environment. It does not run on pushes or pull requests.
Normal `mix test` / `mix ci` selections exclude `tailscale_auth`.

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

### 2. Create a Tailscale OIDC trust credential

Open **Settings → Trust credentials → Credential → OpenID Connect** in Tailscale.
Configure:

| Setting | Value |
| --- | --- |
| Issuer | GitHub Actions (`https://token.actions.githubusercontent.com`) |
| Subject | `repo:sid2baker/nerves_gate:environment:tailnet-ci` |
| Custom claim `repository` | `sid2baker/nerves_gate` |
| Custom claim `ref` | `refs/heads/main` |
| Custom claim `workflow_ref` | `sid2baker/nerves_gate/.github/workflows/tailnet.yml@refs/heads/main` |
| Custom claim `event_name` | `workflow_dispatch` |
| Scopes | **Auth keys: write** (`auth_keys`) and **Devices → Core: write** (`devices:core`) |
| Permitted tag | `tag:ci` |

The environment determines the JWT subject, so the branch restriction belongs in
the `ref` claim as well as GitHub's environment protection. Do not use wildcards or
grant `all`, policy editing, or route-management scopes. Device-core permission is
needed to verify registrations and delete this run's nodes deterministically.

Copy the generated **Client ID** and **Audience**. They are identifiers, not
long-lived authentication secrets. A credential for `tailscaled_ex` is not
sufficient unless its trust rules explicitly authorize this repository; create a
separate narrowly scoped credential instead of broadening that one.

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

After the workflow is on `main`, open **Actions → Tailnet authentication → Run
workflow**, select `main`, and approve the environment if required. The OIDC
preflight runs before firmware building or guest enrollment. Missing settings,
claim mismatches and insufficient permissions fail the run, never silently skip it.

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
GitHub logs. Do not enable HTTP/request tracing or tee workflow stdout into files:
GitHub masking commands themselves contain credential values. This workflow uploads
no raw daemon logs, VM disks, or identity files, and caches only verified downloads.

References: [workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation),
[trust-credential scopes](https://tailscale.com/kb/1623/trust-credentials).

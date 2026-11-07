# Verify security properties

Use this method when the candidate crosses a trust boundary or changes
authentication, authorization, untrusted input, secrets, sensitive data,
external calls, dependencies, or destructive paths.

1. Name the assets that need protection and the actors that can reach them.
2. Map each trust boundary where data, identity, authority, or control crosses
   into the system. Trust follows who wrote a value, not the channel that
   carried it.
3. For each boundary, test the relevant threat classes: impersonation,
   tampering, denied actions without an audit trail, information disclosure,
   resource exhaustion, and privilege escalation.
4. Verify authorization at the affected resource, not only authentication at
   the entry point.
5. Check validation, encoding, query construction, error output, logging,
   secret handling, dependency state, and safe limits where they apply.
6. For a derived file or command target, resolve it and prove that it stays
   below an allowed root and has valid ownership evidence before a destructive
   operation.
7. Prove important findings with a safe test, request, static path, dependency
   report, or complete failure-path analysis. Do not run an exploit against a
   live system without explicit authority.

When repository-scoped MCP configuration or an MCP package selector is the
security surface, also read
[mcp-dependency-review.md](mcp-dependency-review.md). That method is static and
must not start a configured server.

Report the boundary, asset, threat, reachable failure path, consequence,
evidence, and missing control. Separate confirmed vulnerabilities from
hardening suggestions and unknowns. Do not include a secret or usable exploit
payload in the report.

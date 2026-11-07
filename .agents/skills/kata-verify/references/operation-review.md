# Verify an operation

Use this method for a repository action, deployment, migration, service change,
or external-system operation.

1. Identify the target system, requested change, starting state, and final
   state.
2. Observe the authoritative final state. Do not accept a command exit code as
   the only proof when the system can reject, defer, or partly apply the change.
3. Confirm scope: changed targets match the request and unrelated targets did
   not change.
4. Check failure handling, retry safety, idempotency, rollback or recovery, and
   any residual work.
5. For migrations or deployments, check compatibility during the transition,
   current health signals, data integrity, and the rollback trigger.
6. For remote writes, confirm that the observed identity, repository, branch,
   account, region, or environment is the intended target.

Report the before and after states, direct observations, partial failures,
recovery state, and remaining operator action. Do not retry or repair the
operation unless a separate work assignment authorizes it.

# Architecture rules

Load this file for `focus:architecture` or when an explicit project architecture
policy or repeated escaped defect applies.

## `architecture-policy-violation` version 1

- **Use when:** The project defines dependency, namespace, ownership, or boundary
  policy.
- **Detect:** Run the configured check and trace the reported edge.
- **Finding:** One dependency violates an established direction or owner.
- **Fix:** Move behavior to its owner, use an existing inversion contract, or
  remove the unnecessary edge.
- **Protect:** Behavior, ownership, and public contracts.
- **Verify:** The architecture gate and affected tests pass.
- **Judgment stop:** The correct owner, boundary, or policy is not established.
- **Batch key:** Policy rule and dependency edge group.

## `backpressure-capability-gap` version 1

- **Use when:** Project policy requires a missing check, or the same escaped
  defect class has at least two verified occurrences.
- **Detect:** Record the policy or history and prove that the current gate cannot
  detect the class.
- **Finding:** One missing executable guard permits a demonstrated defect class.
- **Fix:** Prefer architecture or types, then an existing lint, test, or CI gate.
- **Protect:** Contributor workflow, supported environments, and current gates.
- **Verify:** The guard fails on a real past bad case and passes on the corrected
  state.
- **Judgment stop:** A dependency, CI policy, exception process, or cross-team
  owner is required. This rule is not eligible for automatic application.
- **Batch key:** Defect class and guard owner.

# Verify blast radius

Use this method when a change can affect callers, stored data, wire formats,
runtime order, another language, a dependency, a feature flag, or a downstream
consumer outside the visible diff.

1. Read the change and its intent. State the behavior difference that the diff
   does not make obvious.
2. Find the one or two facts that make the change safe. A caller list alone is
   not proof.
3. Follow effects past symbol search. Check pinned dependency source, local
   patches, schemas, serialization, lifecycle order, storage, and consumers in
   other processes or repositories when they are in scope.
4. Separate confirmed risks from cleared risks. Give each risk a real failure
   path, likelihood, cost, and source location.
5. Prove the key safety fact at the strongest practical level:
   - source line;
   - complete failure-path analysis;
   - a script or test that calls the real code; or
   - reproduction in the running application.

Report what the change does, the key safety fact and proof level, confirmed
risks, cleared risks, and the cheapest check that would catch the material
failure. Mark the safety fact unproven when direct proof is unavailable.

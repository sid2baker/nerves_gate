# Use a focused failing test

Use this method when the user requests test-driven development, a failing test,
or a regression test, or when a defect has an obvious cheap local test target.
Skip it when the test path is unclear, expensive, integration-heavy, or outside
the request.

1. State the intended behavior, current behavior, affected path, and smallest
   observable reproduction.
2. Select the nearest existing unit, component, integration, or regression test
   boundary.
3. Add the smallest test that expresses the intended behavior without copying
   implementation details.
4. Run it before the production change. Confirm that it fails for the defect,
   not for setup or another reason.
5. Make the smallest production correction.
6. Run the focused test again and then the applicable nearby checks.

Do not force a new test that needs broad harness setup, brittle mocks, slow
infrastructure, production-only state, or unrelated fixture changes. Use the
closest executable regression check instead, such as a script, manual command,
browser path, snapshot comparison, log assertion, or focused integration check.

Do not weaken a correct assertion to match wrong behavior. Keep the regression
test focused. Report the failing-before and passing-after commands and results.
When failing-before evidence is unavailable, state why and name the closest
check used.

# Run an adversarial verification

Use this method only when the user asks to interrogate, challenge, stress test,
or try to break a change or design. Restate the scoped intent first.

Try three different failure angles. Use separate agents only when the user asks
for parallel or multi-agent review. Otherwise, run the angles in sequence and
state that they are not independent.

For each angle, try to prove a failure against the real code. Use a failing
test, reproduction script, command output, prototype, or direct probe. Drop
style opinions, naming preferences, future risks without a current failure
path, and every claim that no run supports.

Rerun each proof when it is safe. Keep a finding only when the output is wrong
and violates the stated intent. Merge findings with one root cause.

Report the intent, each surviving finding with its exact command and observed
result, and the number of dropped claims with their reason. No verified
findings is a valid result.

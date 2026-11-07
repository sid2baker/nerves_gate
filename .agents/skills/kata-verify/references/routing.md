# Verification routing

Use the candidate and claim shape to select the smallest useful method set.

| Context or claim | Primary method | Add when material |
| --- | --- | --- |
| Software behavior or regression | Direct acceptance with an executed behavior check | Code review, blast radius, or security |
| Diff, branch, patch, or pull request | Code review | Blast radius, security, benchmark, or adversarial review |
| Numeric speed, memory, throughput, or cost | Benchmark | Blast radius when the improvement can move cost elsewhere |
| Public API, stored data, schema, dependency, wire format, or lifecycle | Blast radius | Code review or operation review |
| Authentication, authorization, untrusted input, secrets, sensitive data, external calls, dependency risk, or destructive path | Security review | Adversarial review for an explicit attack request |
| Explicit challenge, interrogation, stress test, or “try to break it” | Adversarial review | The context-specific direct method |
| Candidate guard for a repeated repository mistake | Repository-guard verification | Code review when diff scope or repository rules are also material |
| Document, image, UI artifact, generated file, or rendered output | Artifact review | Comment review or direct content checks |
| Research, recommendation, analysis, or decision memo | Research review | Adversarial review when the user asks to challenge the reasoning |
| Deployment, migration, repository action, service change, or remote operation | Operation review | Security or blast radius |
| Interactive CLI, TUI, browser, IDE, or Electron behavior with an existing harness | Application review | Benchmark, security, or artifact review |
| AI feature, agent, prompt, model configuration, or variable-output behavior | AI behavior review | Benchmark, security, or adversarial review |
| Skill package | Direct structure and contract checks | Dojo only on an explicit Dojo request |

## Selection rules

1. Direct acceptance is always present.
2. An explicit named concern selects its method when that method can inspect the
   candidate.
3. A high-risk surface selects its method even when the user does not know its
   name.
4. Do not select a method only because the method exists.
5. Use at most three focused methods by default.
6. Prefer one method that covers several conditions over several duplicate
   methods.
7. Stop when a material failure is proved and more checks cannot change the
   next action.

## Method boundary

Verification judges an existing result. When a method discovers that the
acceptance contract itself is missing or disputed, return unknown and name the
accountable decision. When a method finds a defect, report it and return the
candidate to work. Do not repair it inside verification.

# Skill template

Use this template when the target library has no stricter shape. Combine or omit
conditional sections when the contract stays explicit. Do not create empty
sections to display the template.

```markdown
---
name: <stable-name>
description: <distinctive result; one condition per activation branch>
metadata:
  schema: kata.skill/v1
  subject: <knowledge-domain>
  practice: <kind-of-work>
  object: <primary-object>
  profile: <work-profile>
  authority: <action-class>
  consumes: "<input-type>"
  produces: "<output-type>"
---

# <Skill Name>

**Outcome:** <result> for <next consumer>.

**Done:** <one observable condition that proves the assigned result is complete>.

## Assignment

- Required input: <facts that cannot be derived safely>
- Authority: <source, target, permitted actions, exclusions, confirmation>
- Roles: <only relationships that affect execution or acceptance>
- Escalation: <condition and recipient>

## Work

<Required context and falsifiable protocol. Leave valid implementation choices
to judgment. State what happens after a failed check and when work must stop.
Put conditional detail behind a pointer at its decision point.>

## Verify

<Mechanical checks and behavioral evidence required by the risk and reach of
this skill. State the exact result or unmet condition.>
```

Before completion, confirm that each metadata value agrees with the skill
contract and that any evidence-backed execution profile is recorded where the
target library requires it.

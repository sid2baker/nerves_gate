# Explain an existing software system

Use this mode when the question asks how a feature works, where behavior is
implemented, or what requirements and limits apply.

1. Resolve one scoped question and target system. Read applicable project
   instructions and preserve repository state.
2. Use the root README and documentation index to locate relevant guides. Read
   the smallest useful set of documentation, source, configuration, and tests.
3. Follow public entry points and data flow until the requested behavior and its
   important limits are supported. Stop when further inspection cannot change
   the answer materially.
4. Use code and configuration as evidence of implemented behavior, tests as
   evidence of expected behavior, and documentation as evidence of requirements
   or intent. Report conflicts with references to both sides.
5. Support each material claim with a current file and relevant line when the
   source permits it. Separate confirmed facts, supported deductions, and
   missing evidence.
6. For a rationale question, use decision records, comments, or relevant
   history. Do not infer design history from implementation alone.

Answer the question first in direct language. Include prerequisites, limits,
and unresolved questions. State what static inspection cannot confirm. Do not
claim that tests passed or deployed behavior was verified without current
execution evidence.

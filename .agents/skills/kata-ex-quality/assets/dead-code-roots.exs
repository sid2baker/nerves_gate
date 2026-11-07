# Declared roots for the transitive dead-code analyzer.
# This bundled file is a template.
# Save project entries in the target repository and select it with --roots FILE.
# Keep a literal map. Its optional keys are public_api paths and roots
# {path, reason} pairs. Use each key at most once and use only strings.
# Comments and path globs are supported.
# Code expressions, including function calls and interpolation, are rejected.
#
# A root is code reachable from outside this repository -- by a downstream user,
# by the BEAM, by a CLI, or by runtime wiring no static analysis can follow.
# Everything not transitively reachable from a root is a deletion candidate.
#
# THIS FILE IS THE RATCHET. When the analyzer proposes a cluster and the
# verification gate proves it live, the fix is not to tweak the analyzer -- it
# is to add the entry point here with the reason it is reachable. The noise
# floor then drops permanently, and this file accumulates into documentation of
# the dynamic-wiring surface, which is knowledge a codebase usually records
# nowhere else.
#
# This is the only project-specific file in the skill. Start by filling in
# `public_api`; until you do, almost everything will look dead, because nothing
# is reachable from anywhere.

%{
  # Your application's or library's entry points -- what the outside world calls.
  #
  # For a library, that is the published API surface. Those modules can never be
  # *proven* dead from inside the repo, since a downstream user may call them, so
  # the analyzer reports uncalled ones as advisory rather than proposing deletion.
  #
  # For an application, this is usually much smaller: the Application module, the
  # endpoint or router, whatever the release actually starts.
  public_api: [
    # "lib/my_app.ex",
    # "lib/my_app/application.ex"
  ],

  # Reachable, but not by any edge the graph can see. Paths may contain globs,
  # so one dynamically-dispatched family is one entry with one reason.
  #
  # Two classes are rooted automatically and never need listing: anything under
  # a `lib/mix/` directory, and any module named in a discovered project's
  # `config/*.exs`.
  #
  # Write the reason for someone who does not already know why it is alive:
  #
  #   {"lib/my_app/workers/*.ex", "Enqueued by name from the job queue"},
  #   {"lib/my_app/telemetry.ex", "Attached as a handler by Application.start/2"}
  roots: [
    # -- add confirmed false positives here, with the reason --
  ]
}

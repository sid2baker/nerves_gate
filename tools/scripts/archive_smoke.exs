Code.require_file("../lib/archive_smoke.ex", __DIR__)
[archive] = System.argv()
NervesGateTools.ArchiveSmoke.run!(archive)
IO.puts("Installed archive generated a complete workspace outside the checkout.")

Code.require_file("archive_smoke.ex", __DIR__)
[archive] = System.argv()
NervesGate.ArchiveSmoke.run!(archive)
IO.puts("Installed archive generated a complete workspace outside the checkout.")

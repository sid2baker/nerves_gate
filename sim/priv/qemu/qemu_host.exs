# flock holds the session lock for this host launcher and its cleanup.
NervesGateSim.configure()
[dir | args] = System.argv()
Mix.Tasks.Qemu.Dev.session(dir, args)

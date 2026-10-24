# flock holds the session lock for this host launcher and its cleanup.
Workbench.configure()
[dir | args] = System.argv()
Workbench.Launcher.session(dir, args)

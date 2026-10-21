# flock holds the session lock for this host launcher and its cleanup.
Dev.configure()
[dir | args] = System.argv()
Dev.Launcher.session(dir, args)

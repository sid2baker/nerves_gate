Code.require_file("../lib/workbench/target_build.ex", __DIR__)
:ok = Workbench.TargetBuild.verify!(Path.expand("..", __DIR__))
IO.puts("Native target ports use the musl loader.")

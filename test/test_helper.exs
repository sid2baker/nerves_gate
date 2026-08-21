for file <- Path.wildcard(Path.join(__DIR__, "support/**/*.ex")), do: Code.require_file(file)

ExUnit.start(exclude: [:integration])

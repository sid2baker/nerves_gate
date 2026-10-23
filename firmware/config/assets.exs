import Config

root = Path.expand("../..", __DIR__)
firmware = Path.join(root, "firmware")

# One asset definition for workbench development and firmware packaging. All
# paths are absolute so host builds do not depend on the caller's directory.
config :volt,
  entry: Path.join(firmware, "assets/js/app.js"),
  root: Path.join(firmware, "assets"),
  sources: ["**/*.js"],
  outdir: Path.join(firmware, "priv/static/assets"),
  resolve_dirs: [Path.join(root, "deps"), Path.join(firmware, "deps")],
  target: :es2020,
  format: :esm,
  hash: false,
  code_splitting: false,
  sourcemap: false,
  tailwind: [
    css: Path.join(firmware, "assets/css/app.css"),
    sources: [
      %{base: Path.join(firmware, "lib"), pattern: "**/*.{ex,heex}"},
      %{base: Path.join(root, "lib"), pattern: "**/*.ex"},
      %{base: Path.join(firmware, "assets"), pattern: "**/*.js"}
    ]
  ]

config :volt, :server,
  prefix: "/assets",
  watch_dirs: [Path.join(firmware, "lib"), Path.join(root, "lib")]

import Config

# Host builds are for quality checks and asset builds only. The workstation UI and
# QEMU devices are owned by ../sim, which supplies its own configuration.
config :nerves_gate, services: []

# Stable entry names let firmware use Phoenix static paths without loading Volt.
config :volt,
  entry: "assets/js/app.js",
  root: "assets",
  sources: ["**/*.js"],
  outdir: "priv/static/assets",
  resolve_dirs: ["deps"],
  target: :es2020,
  format: :esm,
  hash: false,
  code_splitting: false,
  sourcemap: false,
  tailwind: [
    css: "assets/css/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "../sim/lib/", pattern: "**/*.ex"},
      %{base: "assets/", pattern: "**/*.js"}
    ]
  ]
